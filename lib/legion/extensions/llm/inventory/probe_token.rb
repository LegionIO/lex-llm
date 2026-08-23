# frozen_string_literal: true

require 'securerandom'
require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/inventory/identity'

module Legion
  module Extensions
    module Llm
      module Inventory
        # An opaque fenced publisher claim token. The raw secret is never
        # serialized, logged, included in a record/snapshot/exception, returned
        # separately, or compared for order. `publisher_id` and
        # `publisher_token_id` are safe UUID correlation values — the id law
        # forbids digest-encoded ids on any wire/DB/log surface, so the token
        # id is a UUID like every other lifecycle handle, NOT a derivation of
        # the secret. Fencing is the constant-time secret comparison; the
        # public ids correlate, they do not authenticate.
        # See phase-1-lex-llm-additive.md section 11.1.
        class PublisherToken
          attr_reader :instance_key, :publisher_id, :publisher_token_id

          # Factory used by the registry: builds a fresh secret and mints the
          # public correlation IDs.
          def self.issue(instance_key:)
            secret = ::SecureRandom.hex(32)
            new(
              instance_key: instance_key, secret: secret,
              publisher_id: "pub:v1:#{::SecureRandom.uuid}", publisher_token_id: "ptok:v1:#{::SecureRandom.uuid}"
            )
          end

          def initialize(instance_key:, secret:, publisher_id:, publisher_token_id:)
            raise Errors::ValidationError, 'instance_key must be an InstanceKey' unless instance_key.is_a?(Identity::InstanceKey)
            raise Errors::ValidationError, 'secret must be a nonempty String' unless nonempty_string?(secret)
            raise Errors::ValidationError, 'publisher_id must be a pub:v1: String' unless publisher_id.to_s.start_with?('pub:v1:')
            raise Errors::ValidationError, 'publisher_token_id must be a ptok:v1: String' unless publisher_token_id.to_s.start_with?('ptok:v1:')

            @instance_key = instance_key
            @secret = secret.b.dup.freeze
            @publisher_id = publisher_id.dup.freeze
            @publisher_token_id = publisher_token_id.dup.freeze
            freeze
          end

          # Fenced validation: same InstanceKey, same public token ID, and a
          # constant-time equal-length secret comparison using a local XOR
          # accumulator (no ActiveSupport).
          def authenticates?(other)
            other.is_a?(PublisherToken) &&
              instance_key == other.instance_key &&
              publisher_token_id == other.publisher_token_id &&
              secrets_match?(other)
          end

          def inspect
            "#<#{self.class.name} instance_key=#{@instance_key.inspect} " \
              "publisher_id=#{@publisher_id} publisher_token_id=#{@publisher_token_id} secret=[REDACTED]>"
          end
          alias to_s inspect

          protected

          def secret_bytes
            @secret
          end

          private

          def secrets_match?(other)
            mine = @secret
            theirs = other.secret_bytes
            return false unless mine.bytesize == theirs.bytesize

            accumulator = 0
            mine.bytes.each_with_index { |byte, index| accumulator |= byte ^ theirs.getbyte(index) }
            accumulator.zero?
          end

          def nonempty_string?(value)
            value.is_a?(::String) && !value.empty?
          end
        end

        # A single-use safe-readiness probe token. Carries no secret. See 11.2.
        ProbeToken = ::Data.define(:token_id, :instance_key, :publisher_token_id, :started_availability_revision, :started_at) do
          def self.issue(instance_key:, publisher_token_id:, started_availability_revision:, started_at:)
            new(
              token_id: "probe:v1:#{::SecureRandom.uuid}", instance_key: instance_key,
              publisher_token_id: publisher_token_id, started_availability_revision: started_availability_revision,
              started_at: started_at
            )
          end

          def initialize(token_id:, instance_key:, publisher_token_id:, started_availability_revision:, started_at:)
            raise Errors::ValidationError, 'instance_key must be an InstanceKey' unless instance_key.is_a?(Identity::InstanceKey)
            raise Errors::ValidationError, 'token_id must be a probe:v1: String' unless token_id.to_s.start_with?('probe:v1:')
            raise Errors::ValidationError, 'publisher_token_id must be a ptok:v1: String' unless publisher_token_id.is_a?(::String) && publisher_token_id.start_with?('ptok:v1:')
            unless started_availability_revision.is_a?(::Integer) && !started_availability_revision.negative?
              raise Errors::ValidationError, 'started_availability_revision must be a nonnegative Integer'
            end
            raise Errors::ValidationError, 'started_at must be a Time' unless started_at.is_a?(::Time)

            super(
              token_id: token_id.dup.freeze, instance_key: instance_key,
              publisher_token_id: publisher_token_id.dup.freeze,
              started_availability_revision: started_availability_revision, started_at: started_at.dup.freeze
            )
          end
        end

        # A process-local enqueue value asking the owning provider actor to run
        # its safe readiness operation. Grants no registry mutation authority and
        # carries no authorization secret. See section 11.2.
        ProbeRequest = ::Data.define(:instance_key, :publisher_token_id, :unavailable_revision, :reason) do
          def initialize(instance_key:, publisher_token_id:, unavailable_revision:, reason:)
            raise Errors::ValidationError, 'instance_key must be an InstanceKey' unless instance_key.is_a?(Identity::InstanceKey)
            raise Errors::ValidationError, 'publisher_token_id must be a nonempty ptok:v1: String' unless publisher_token_id.is_a?(::String) && publisher_token_id.start_with?('ptok:v1:')
            raise Errors::ValidationError, 'unavailable_revision must be a positive Integer' unless unavailable_revision.is_a?(::Integer) && unavailable_revision.positive?

            super(
              instance_key: instance_key, publisher_token_id: publisher_token_id.dup.freeze,
              unavailable_revision: unavailable_revision, reason: sanitized_reason(reason)
            )
          end

          def sanitized_reason(reason)
            unless reason.is_a?(::String) &&
                   [::Encoding::UTF_8, ::Encoding::US_ASCII].include?(reason.encoding) && reason.valid_encoding?
              raise Errors::ValidationError, 'reason must be a valid UTF-8 String'
            end

            trimmed = reason.strip
            raise Errors::ValidationError, 'reason must not be empty' if trimmed.empty?
            raise Errors::ValidationError, 'reason exceeds 1024 UTF-8 bytes' if trimmed.bytesize > 1024

            trimmed.b.dup.force_encoding(::Encoding::UTF_8).freeze
          end
        end
      end
    end
  end
end
