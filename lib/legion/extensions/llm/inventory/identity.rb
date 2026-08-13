# frozen_string_literal: true

require 'digest'
require 'legion/extensions/llm/inventory/errors'

module Legion
  module Extensions
    module Llm
      module Inventory
        # Canonical field normalization plus the `off:v1:` and `lane:v1:`
        # length-framed SHA-256 encoders/validators. See
        # phase-1-lex-llm-additive.md section 8.
        #
        # Framing is binary: decimal UTF-8 byte length, ASCII ':', then the exact
        # UTF-8 bytes. It never uses a delimiter join, Ruby hash order, object ID,
        # or Ruby Hash#hash. Tier is never an identity input.
        module Identity
          module_function

          def normalize_text(value:, field:)
            raise Errors::ValidationError, "#{field} must be a String or Symbol" unless text_input?(value)

            string = value.to_s
            raise Errors::ValidationError, "#{field} is not valid UTF-8" unless valid_utf8?(string)

            trimmed = utf8(string).strip
            raise Errors::ValidationError, "#{field} must not be empty" if trimmed.empty?
            raise Errors::ValidationError, "#{field} must be NFC-normalized" unless trimmed.unicode_normalized?(:nfc)

            trimmed.freeze
          end

          def normalize_enum(value:, field:, allowed:)
            raise Errors::ValidationError, "#{field} must be a String or Symbol" unless text_input?(value)

            trimmed = value.to_s.strip
            raise Errors::ValidationError, "#{field} must not be empty" if trimmed.empty?

            candidate = trimmed.to_sym
            raise Errors::ValidationError, "#{field} is not one of the allowed values" unless allowed.include?(candidate)

            candidate
          end

          def length_frame(value:)
            bytes = value.to_s.b
            "#{bytes.bytesize}:".b + bytes
          end

          def offering_id(instance_key:, provider_native_key:)
            digest = ::Digest::SHA256.hexdigest(
              length_frame(value: instance_key.provider_family) +
              length_frame(value: instance_key.instance_id) +
              length_frame(value: provider_native_key)
            )
            "off:v1:#{digest}"
          end

          def lane_id(instance_key:, operation:, model:, offering_id:)
            digest = ::Digest::SHA256.hexdigest(
              "lane-v1\x00".b +
              length_frame(value: instance_key.provider_family) +
              length_frame(value: instance_key.instance_id) +
              length_frame(value: operation) +
              length_frame(value: model) +
              length_frame(value: offering_id)
            )
            "lane:v1:#{digest}"
          end

          def validate_offering_id!(value:, instance_key:, provider_native_key:)
            expected = offering_id(instance_key: instance_key, provider_native_key: provider_native_key)
            raise Errors::ValidationError, 'offering_id does not reproduce from its identity fields' unless value == expected

            value
          end

          def validate_lane_id!(value:, instance_key:, operation:, model:, offering_id:)
            expected = lane_id(
              instance_key: instance_key, operation: operation, model: model, offering_id: offering_id
            )
            raise Errors::ValidationError, 'lane_id does not reproduce from its identity fields' unless value == expected

            value
          end

          def text_input?(value)
            value.is_a?(::String) || value.is_a?(::Symbol)
          end

          def valid_utf8?(string)
            [::Encoding::UTF_8, ::Encoding::US_ASCII].include?(string.encoding) && string.valid_encoding?
          end

          def utf8(string)
            string.encoding == ::Encoding::UTF_8 ? string.dup : string.b.dup.force_encoding(::Encoding::UTF_8)
          end

          private_class_method :text_input?, :valid_utf8?, :utf8

          # A mandatory, immutable provider_family + instance_id pair. Provider
          # family alone is never executable; two instances of the same provider
          # are independent targets. See section 8.1.
          InstanceKey = ::Data.define(:provider_family, :instance_id) do
            def initialize(provider_family:, instance_id:)
              family = Identity.normalize_text(value: provider_family, field: :provider_family).downcase
              raise Errors::ValidationError, 'provider_family must match /\A[a-z][a-z0-9_]*\z/' unless family.match?(/\A[a-z][a-z0-9_]*\z/)

              instance = Identity.normalize_text(value: instance_id, field: :instance_id)
              raise Errors::ValidationError, 'instance_id must not be the reserved value "default"' if instance == 'default'

              super(provider_family: family.to_sym, instance_id: instance)
            end
          end
        end
      end
    end
  end
end
