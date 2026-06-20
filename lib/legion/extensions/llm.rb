# frozen_string_literal: true

require 'base64'
require 'date'
require 'digest/sha1'
require 'event_stream_parser'
require 'faraday'
require 'faraday/multipart'
require 'faraday/retry'
require 'legion/json'
require 'legion/logging'
# legion/cache writes DEBUG lines to $stdout on first load; suppress them here
# so callers that capture our stdout (e.g. Open3-based integration tests) are unaffected.
begin
  old_stdout = $stdout
  $stdout = File.open(File::NULL, 'w')
  require 'legion/cache'
ensure
  $stdout = old_stdout
end
require 'logger'
require 'marcel'
require 'ruby_llm/schema'
require 'securerandom'
require 'time'
require_relative 'llm/version'

module Legion
  module Extensions
    # Legion-native namespace for the shared LLM provider framework.
    module Llm
      # ------------------------------------------------------------------ #
      #  Explicit requires (replaces Zeitwerk autoloading).                 #
      #  Load order: base classes & canonical types first, then anything    #
      #  that references them. All live under Legion::Extensions::Llm so    #
      #  unqualified constant lookups resolve via Ruby scope.               #
      # ------------------------------------------------------------------ #

      # --- P1 SSOT: taxonomy enums, capability normalization, inventory writer mixin ---
      require_relative 'llm/taxonomies'
      require_relative 'llm/capabilities'
      require_relative 'llm/inventory/scoped_refresher'
      require_relative 'llm/inventory/capabilities'

      # --- Capability resolution policy (no internal deps) ---
      require_relative 'llm/capability_policy'

      # --- Base value objects (no internal deps) ---
      require_relative 'llm/mime_type'
      require_relative 'llm/model/info'
      require_relative 'llm/model/modalities'
      require_relative 'llm/model/pricing_category'
      require_relative 'llm/model/pricing_tier'
      require_relative 'llm/model/pricing'
      require_relative 'llm/configuration'
      require_relative 'llm/thinking'
      require_relative 'llm/tokens'
      require_relative 'llm/message'
      require_relative 'llm/tool_call'
      require_relative 'llm/content'
      require_relative 'llm/errors/unsupported_capability'
      require_relative 'llm/error'

      # --- Build on message/base types ---
      require_relative 'llm/chunk'
      require_relative 'llm/model'
      require_relative 'llm/attachment'

      # --- Streaming fundamentals (must load before streaming/provider) ---
      require_relative 'llm/stream_accumulator'
      require_relative 'llm/responses/stream_chunk'
      require_relative 'llm/streaming'

      # --- Context, Connection ---
      require_relative 'llm/context'
      require_relative 'llm/connection'

      # --- Response normalizers ---
      require_relative 'llm/responses/chat_response'
      require_relative 'llm/responses/embedding_response'
      require_relative 'llm/responses/thinking_extractor'

      # --- Provider base & allied modules ---
      require_relative 'llm/provider_contract'
      require_relative 'llm/provider_settings'
      require_relative 'llm/provider'

      # --- Provider subtypes ---
      require_relative 'llm/provider/open_ai_compatible'

      # --- Routing ---
      require_relative 'llm/routing'
      require_relative 'llm/routing/lane_key'
      require_relative 'llm/routing/offering_registry'
      require_relative 'llm/routing/registry_event'
      require_relative 'llm/routing/model_offering'

      # --- Models (scans for Provider subclasses) ---
      require_relative 'llm/models'

      # --- Agent & Chat (reference Provider, Context, Chat at method-time) ---
      require_relative 'llm/agent'
      require_relative 'llm/chat'

      # --- Domain services ---
      require_relative 'llm/embedding'
      require_relative 'llm/moderation'
      require_relative 'llm/image'
      require_relative 'llm/transcription'

      # --- Registry & misc support ---
      require_relative 'llm/registry_event_builder'
      require_relative 'llm/registry_publisher'
      require_relative 'llm/auto_registration'
      require_relative 'llm/credential_sources'
      require_relative 'llm/tool'
      require_relative 'llm/utils'
      require_relative 'llm/aliases'

      # --- Fleet protocol (depends on Provider, Models) ---
      require_relative 'llm/fleet/protocol'
      require_relative 'llm/fleet/settings'
      require_relative 'llm/fleet/token_error'
      require_relative 'llm/fleet/envelope_validation'
      require_relative 'llm/fleet/publish_safety'
      require_relative 'llm/fleet/default_exchange_reply'
      require_relative 'llm/fleet/token_validator'
      require_relative 'llm/fleet/worker_execution'
      require_relative 'llm/fleet/provider_responder'

      # --- Transport lane (references Fleet exchange/message autoloads) ---
      require_relative 'llm/transport/fleet_lane'

      # --- Canonical types — explicit self-contained loader ---
      require_relative 'llm/canonical'

      # --- Transport modules (lazy — depend on optional legion-transport) ---
      # These remain as autoload so boot-time does not force legion-transport.
      module Transport
        # Shared AMQP exchange definitions for fleet routing.
        # Lazy-loaded; only instantiated when legion-transport is available.
        module Exchanges
          autoload :Fleet, File.expand_path('llm/transport/exchanges/fleet', __dir__)
        end

        # Shared AMQP message envelopes for fleet request/response cycles.
        # Lazy-loaded; only instantiated when legion-transport is available.
        module Messages
          autoload :FleetRequest, File.expand_path('llm/transport/messages/fleet_request', __dir__)
          autoload :FleetResponse, File.expand_path('llm/transport/messages/fleet_response', __dir__)
          autoload :FleetError, File.expand_path('llm/transport/messages/fleet_error', __dir__)
        end
      end

      Schema = ::RubyLLM::Schema unless const_defined?(:Schema, false)

      # Provider-neutral value objects exposed under the Legion extension namespace.
      module Types
        ModelOffering = Routing::ModelOffering unless const_defined?(:ModelOffering, false)
        OfferingRegistry = Routing::OfferingRegistry unless const_defined?(:OfferingRegistry, false)
        RegistryEvent = Routing::RegistryEvent unless const_defined?(:RegistryEvent, false)
      end

      # Shared routing helpers exposed under the Legion extension namespace.
      module Routing
        LaneKey = ::Legion::Extensions::Llm::Routing::LaneKey unless const_defined?(:LaneKey, false)
        OfferingRegistry = ::Legion::Extensions::Llm::Routing::OfferingRegistry unless const_defined?(:OfferingRegistry,
                                                                                                      false)
        RegistryEvent = ::Legion::Extensions::Llm::Routing::RegistryEvent unless const_defined?(:RegistryEvent, false)
      end

      class << self
        def remote_invocable? = false

        def context
          context_config = config.dup
          yield context_config if block_given?
          Context.new(context_config)
        end

        def chat(...)
          Chat.new(...)
        end

        def embed(...)
          Embedding.embed(...)
        end

        def moderate(...)
          Moderation.moderate(...)
        end

        def paint(...)
          Image.paint(...)
        end

        def transcribe(...)
          Transcription.transcribe(...)
        end

        def models
          Models.instance
        end

        def providers
          Models.scan_provider_classes.values
        end

        def configure
          yield config
        end

        def config
          @config ||= Configuration.new
        end

        def logger
          @logger ||= config.logger || Logger.new(
            config.log_file,
            progname: 'Legion::Extensions::Llm',
            level: config.log_level
          )
        end
      end

      def self.default_settings
        {
          fleet: {
            consumer: {
              enabled: false,
              scheduler: :basic_get,
              consumer_priority: 0,
              queue_expires_ms: 60_000,
              message_ttl_ms: 120_000,
              queue_max_length: 100,
              delivery_limit: 3,
              consumer_ack_timeout_ms: 90_000,
              empty_lane_backoff_ms: 250,
              idle_backoff_ms: 1_000,
              max_consecutive_pulls_per_lane: 0
            },
            auth: {
              require_signed_token: true,
              issuer: 'legion-llm',
              audience: 'lex-llm-fleet-worker',
              algorithm: 'HS256',
              accepted_issuers: ['legion-llm'],
              max_clock_skew_seconds: 30,
              replay_ttl_seconds: 600
            },
            responder: {
              require_auth: nil,
              require_policy: false,
              require_idempotency: true,
              idempotency_ttl_seconds: 600
            },
            request: {
              logger: {
                request_payload: false
              }
            }
          }
        }
      end

      def self.provider_settings(...)
        ProviderSettings.build(...)
      end
    end
  end
end
