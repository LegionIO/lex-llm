# frozen_string_literal: true

# -- from_hash normalization is intentional
module Legion
  module Extensions
    # -- module doc is in canonical.rb entry point
    module Llm
      # -- required for Data.define block scope
      module Canonical
        # Canonical thinking/reasoning block.
        # Ports field vocabulary from Legion::LLM::Types and lex-llm Thinking.
        # Empty-string values normalize to nil (absence, not data — 04 §8).
        Thinking = ::Data.define(:content, :signature, :metadata) do
          # Build from keyword args (primary constructor).
          def self.build(content: nil, signature: nil, metadata: {})
            new(
              content: absence!(content, self::BUILD_SITE, :content),
              signature: absence!(signature, self::BUILD_SITE, :signature),
              metadata: Strict.metadata!(metadata, self::BUILD_SITE)
            )
          end

          # Build from a Hash (raw provider response or deserialized wire payload).
          def self.from_hash(source)
            Strict.require_hash!(source, self::FROM_HASH_SITE)
            hash = Strict.symbolize_keys(source)
            metadata = Strict.fold_unknowns!(self, self::FROM_HASH_SITE, hash)
            build(content: hash[:content], signature: hash[:signature], metadata:)
          end

          # Empty-string is absence, not data (04 §8).
          def self.absence!(value, site, member)
            return nil if value.nil?

            Strict.expect_type!(value, [::String], site, member)
            value.empty? ? nil : value
          end

          # Serialize to a Hash for AMQP/fleet/wire transport.
          def to_h
            super.compact
          end

          # MultiJson/Oj/::JSON callback — prevents Data.define #inspect leak into JSON.
          def as_json(*)
            to_h
          end

          def to_json(*)
            to_h.to_json(*)
          end

          # Whether this thinking block has any content.
          def empty?
            content.nil? && signature.nil?
          end

          # H1: the single strict constructor — .new runs the same member
          # contract as the factories; the factories fill their defaults and
          # delegate here.
          Strict.install_strict_new!(self) do |values, site|
            values[:content] = absence!(values[:content], site, :content)
            values[:signature] = absence!(values[:signature], site, :signature)
            values[:metadata] = Strict.metadata!(values[:metadata], site)
            values
          end
        end

        Thinking::BUILD_SITE = 'Canonical::Thinking.build'
        Thinking::FROM_HASH_SITE = 'Canonical::Thinking.from_hash'
        Thinking::NEW_SITE = 'Canonical::Thinking.new'
      end
    end
  end
end

require_relative 'thinking_config'
