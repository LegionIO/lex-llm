# frozen_string_literal: true

require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/taxonomies'

module Legion
  module Extensions
    module Llm
      module Inventory
        # Canonical field normalization plus the ONE 5-tuple lane-id composer.
        # The lane id is `tier:provider_family:instance_id:type:model`, composed
        # here and ONLY here (G22). Every surface that needs an id calls
        # compose_lane_id; validation is shape/parse checks against Taxonomies
        # (R1 boundary contract — it enforces the shape the code produces).
        # The code produces ONLY 5-tuples; nothing else is guarded against.
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

          # The ONE 5-tuple composer (G22): byte-identical to the v0.6.16
          # ScopedRefresher.compose_id. A pure join of the five identity fields —
          # no normalization here; the fields are normalized by their owners
          # (TIERS/TYPES symbols, InstanceKey, normalize_text) before composing.
          def compose_lane_id(tier:, provider_family:, instance_id:, type:, model:)
            "#{tier}:#{provider_family}:#{instance_id}:#{type}:#{model}"
          end

          # Bounded parse: split(':', 5) — the 5th part keeps its colons, which
          # is load-bearing: model names contain ':' (Ollama model:tag, Bedrock
          # model ids). Structural only — field semantics are validate_lane_id!'s.
          def parse_lane_id(id)
            raise Errors::ValidationError, 'lane id must be a String or Symbol' unless text_input?(id)

            parts = id.to_s.split(':', 5)
            raise Errors::ValidationError, "lane id must have exactly 5 parts, got #{parts.length}" unless parts.length == 5

            parts.freeze
          end

          # Shape validation (R1 boundary contract): exactly 5 parts (bounded
          # split — the model keeps its colons), part 1 in TIERS, part 4 in
          # TYPES, parts 2/3/5 nonempty NFC. Any value that is not a 5 tuple
          # fails the part-count check on its own — there is no special case
          # for anything else.
          def validate_lane_id!(value:)
            parts = parse_lane_id(value)
            tier, provider_family, instance_id, type, model = parts
            raise Errors::ValidationError, "lane id tier must be a Taxonomies::TIERS value, got #{tier}" \
              unless Taxonomies::TIERS.include?(tier.to_sym)
            raise Errors::ValidationError, "lane id type must be a Taxonomies::TYPES value, got #{type}" \
              unless Taxonomies::TYPES.include?(type.to_sym)
            raise Errors::ValidationError, 'lane id provider_family must be a nonempty NFC String' \
              unless nonempty_nfc?(provider_family)
            raise Errors::ValidationError, 'lane id instance_id must be a nonempty NFC String' \
              unless nonempty_nfc?(instance_id)
            raise Errors::ValidationError, 'lane id model must be a nonempty NFC String' \
              unless nonempty_nfc?(model)

            value
          end

          def nonempty_nfc?(string)
            !string.empty? && string.unicode_normalized?(:nfc)
          end

          # M6: the ONE config→instance-id derivation (R6 owner law).
          # Instance identity is the operator's CONFIG NAME from the provider
          # config; when the operator configured no instance name, "default"
          # is the ordinary label (no reserved values — see InstanceKey).
          # Consumers CARRY this derivation; they never mint a local variant
          # (node canonical names, family fallbacks, and read-time synthesis
          # are deleted).
          def instance_id(config)
            return config.instance_id.to_s if config.respond_to?(:instance_id) && config.instance_id

            'default'
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

          private_class_method :text_input?, :valid_utf8?, :utf8, :nonempty_nfc?

          # A mandatory, immutable provider_family + instance_id pair. Provider
          # family alone is never executable; two instances of the same provider
          # are independent targets. See section 8.1.
          #
          # instance_id is the operator's CONFIG NAME — the identity the router
          # keys settings lookups (instances.<name>) by. physical_id is an
          # optional SECONDARY field carrying the physical/derived id
          # (e.g. "host:port" or "host:port/ak:<digest>") preserved for dedup
          # and diagnostics. It is NOT identity: it never participates in
          # equality, hashing, or registry-scope identity, so two config names
          # pointing at the same endpoint stay distinct instances.
          #
          # There are NO reserved instance_id values (v2 parity): "default" is
          # an ordinary operator label. Synthetic default-template protection
          # lives provider-side (template-conditional discovery skip).
          InstanceKey = ::Data.define(:provider_family, :instance_id, :physical_id) do
            def initialize(provider_family:, instance_id:, physical_id: nil)
              family = Identity.normalize_text(value: provider_family, field: :provider_family).downcase
              raise Errors::ValidationError, 'provider_family must match /\A[a-z][a-z0-9_]*\z/' unless family.match?(/\A[a-z][a-z0-9_]*\z/)

              instance = Identity.normalize_text(value: instance_id, field: :instance_id)
              physical = physical_id.nil? ? nil : Identity.normalize_text(value: physical_id, field: :physical_id)

              super(provider_family: family.to_sym, instance_id: instance, physical_id: physical)
            end

            # Identity is exactly (provider_family, instance_id). The
            # secondary physical_id never affects equality, hashing, or
            # registry-scope identity.
            def ==(other)
              other.is_a?(self.class) && other.provider_family == provider_family && other.instance_id == instance_id
            end
            alias_method :eql?, :==

            def hash
              [self.class, provider_family, instance_id].hash
            end
          end
        end
      end
    end
  end
end
