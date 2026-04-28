# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Routing
        # Serializable provider-neutral envelope for future llm.registry publishing.
        class RegistryEvent
          EVENT_TYPES = %i[
            offering_available
            offering_unavailable
            offering_degraded
            offering_heartbeat
          ].freeze
          SENSITIVE_KEYS = %i[
            access_key
            api_key
            authorization
            bearer
            client_secret
            credential
            credentials
            endpoint
            endpoint_url
            password
            path
            private_key
            prompt
            reply_to
            secret
            secrets
            token
            url
          ].freeze

          attr_reader :event_id, :event_type, :occurred_at, :offering, :runtime, :capacity, :health, :lane, :metadata

          class << self
            def available(offering, **attributes)
              new(event_type: :offering_available, offering:, **attributes)
            end

            def unavailable(offering, **attributes)
              new(event_type: :offering_unavailable, offering:, **attributes)
            end

            def degraded(offering, **attributes)
              new(event_type: :offering_degraded, offering:, **attributes)
            end

            def heartbeat(offering, **attributes)
              new(event_type: :offering_heartbeat, offering:, **attributes)
            end
          end

          def initialize(event_type:, offering:, **attributes)
            @event_id = normalize_event_id(attributes.fetch(:event_id, SecureRandom.uuid))
            @event_type = normalize_event_type(event_type)
            @occurred_at = normalize_time(attributes.fetch(:occurred_at, Time.now.utc))
            @offering = normalize_offering(offering)
            @runtime = sanitize_optional_hash(attributes[:runtime], :runtime)
            @capacity = sanitize_optional_hash(attributes[:capacity], :capacity)
            @health = sanitize_optional_hash(attributes[:health], :health)
            @lane = sanitize_optional_value(attributes[:lane], :lane)
            @metadata = sanitize_optional_hash(attributes[:metadata], :metadata)
          end

          def to_h
            {
              event_id: event_id,
              event_type: event_type,
              occurred_at: occurred_at.utc.iso8601(6),
              offering: sanitized_offering_hash,
              runtime: runtime,
              capacity: capacity,
              health: health,
              lane: lane,
              metadata: metadata
            }.compact
          end

          private

          def normalize_event_id(value)
            normalized = value.to_s.strip
            raise ArgumentError, 'event_id is required' if normalized.empty?

            normalized
          end

          def normalize_event_type(value)
            normalized = value.to_sym
            raise ArgumentError, "unsupported registry event type: #{value}" unless EVENT_TYPES.include?(normalized)

            normalized
          end

          def normalize_time(value)
            return value.utc if value.respond_to?(:utc)

            Time.parse(value.to_s).utc
          end

          def normalize_offering(value)
            return value if value.is_a?(ModelOffering)

            ModelOffering.new(value)
          end

          def sanitized_offering_hash
            sanitize_hash(offering.to_h, on_sensitive: :drop)
          end

          def sanitize_optional_hash(value, label)
            return nil if value.nil?

            sanitize_hash(value.to_h, label:)
          end

          def sanitize_optional_value(value, label)
            return nil if value.nil?
            return sanitize_hash(value.to_h, label:) if value.respond_to?(:to_h)
            return value unless value.is_a?(Array)

            sanitize_array(value, label:, path: [])
          end

          def sanitize_hash(hash, label: nil, path: [], on_sensitive: :raise)
            hash.each_with_object({}) do |(key, value), sanitized|
              normalized_key = key.to_sym
              key_path = path + [normalized_key]
              if sensitive_key?(normalized_key)
                raise_sensitive_key!(label, key_path) if on_sensitive == :raise

                next
              end

              sanitized[normalized_key] = sanitize_value(value, label:, path: key_path, on_sensitive:)
            end
          end

          def sanitize_array(array, label:, path:, on_sensitive: :raise)
            array.map { |value| sanitize_value(value, label:, path:, on_sensitive:) }
          end

          def sanitize_value(value, label:, path:, on_sensitive:)
            return sanitize_hash(value, label:, path:, on_sensitive:) if value.is_a?(Hash)
            return sanitize_array(value, label:, path:, on_sensitive:) if value.is_a?(Array)

            value
          end

          def sensitive_key?(key)
            normalized = key.to_s.downcase.gsub(/[^a-z0-9]+/, '_').to_sym
            SENSITIVE_KEYS.include?(normalized) ||
              normalized.to_s.end_with?('_key', '_secret', '_token', '_password')
          end

          def raise_sensitive_key!(label, path)
            prefix = label ? "#{label} contains" : 'registry event contains'
            raise ArgumentError, "#{prefix} sensitive key: #{path.join('.')}"
          end
        end
      end
    end
  end
end
