# frozen_string_literal: true

require_relative 'protocol'

module Legion
  module Extensions
    module Llm
      module Fleet
        # Shared validation helpers for strict fleet protocol v2 envelopes.
        module EnvelopeValidation
          LEGACY_OPTIONS = %i[schema_version request_type fleet_correlation_id].freeze

          private

          def reject_legacy_options!
            LEGACY_OPTIONS.each do |key|
              if @options.key?(key) || @options.key?(key.to_s)
                raise ArgumentError, "#{key} is not supported by fleet protocol v2"
              end
            end
          end

          def require_option!(key)
            return if @options.key?(key) && !@options[key].nil?

            raise ArgumentError, "#{key} is required"
          end

          def require_protocol_version!
            version = @options.fetch(:protocol_version, Fleet::Protocol::VERSION)
            return if version == Fleet::Protocol::VERSION

            raise ArgumentError, "protocol_version must be #{Fleet::Protocol::VERSION}"
          end
        end
      end
    end
  end
end
