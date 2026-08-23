# frozen_string_literal: true

require_relative 'protocol'

module Legion
  module Extensions
    module Llm
      module Fleet
        # Shared validation helpers for strict fleet protocol v3 envelopes.
        module EnvelopeValidation
          private

          def reject_legacy_options!
            Fleet::Protocol::LEGACY_FIELDS.each do |key|
              raise ArgumentError, "#{key} is not supported by fleet protocol v3" if @options.key?(key) || @options.key?(key.to_s)
            end
          end

          def require_option!(key)
            return if @options.key?(key) && !@options[key].nil?

            raise ArgumentError, "#{key} is required"
          end

          # P3: explicit version — a missing protocol_version raises; there is
          # no default fill.
          def require_protocol_version!
            version = @options[:protocol_version]
            raise ArgumentError, 'protocol_version is required' if version.nil?
            return if version == Fleet::Protocol::VERSION

            raise ArgumentError, "protocol_version must be #{Fleet::Protocol::VERSION}"
          end
        end
      end
    end
  end
end
