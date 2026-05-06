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
require 'logger'
require 'marcel'
require 'ruby_llm/schema'
require 'securerandom'
require 'time'
require 'zeitwerk'
require_relative 'llm/version'

module Legion
  module Extensions
    # Legion-native namespace for the shared LLM provider framework.
    module Llm
      loader = Zeitwerk::Loader.new
      loader.tag = 'lex-llm'
      loader.inflector.inflect(
        'api' => 'API',
        'llm' => 'Llm',
        'open_ai_compatible' => 'OpenAICompatible',
        'pdf' => 'PDF',
        'ui' => 'UI'
      )
      loader.ignore("#{__dir__}/llm/version.rb")
      loader.ignore("#{__dir__}/llm/auto_registration.rb")
      loader.ignore("#{__dir__}/llm/credential_sources.rb")
      loader.ignore("#{__dir__}/llm/transport/exchanges")
      loader.ignore("#{__dir__}/llm/transport/messages")
      loader.push_dir("#{__dir__}/llm", namespace: self)
      loader.setup

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
            }
          }
        }
      end

      def self.provider_settings(...)
        ProviderSettings.build(...)
      end

      require_relative 'llm/auto_registration'
      require_relative 'llm/credential_sources'
      loader.eager_load

      module Transport
        # Local autoloads for fleet exchange classes that depend on legion-transport.
        module Exchanges
          autoload :Fleet, File.expand_path('llm/transport/exchanges/fleet', __dir__)
        end

        # Local autoloads for fleet message classes that depend on legion-transport.
        module Messages
          autoload :FleetRequest, File.expand_path('llm/transport/messages/fleet_request', __dir__)
          autoload :FleetResponse, File.expand_path('llm/transport/messages/fleet_response', __dir__)
          autoload :FleetError, File.expand_path('llm/transport/messages/fleet_error', __dir__)
        end
      end
    end
  end
end
