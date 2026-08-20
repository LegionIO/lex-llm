# frozen_string_literal: true

# rubocop:disable Metrics/ParameterLists -- factory methods have many params
module Legion
  module Extensions
    module Llm
      module Canonical
        # Typed content block with media_type support per G20a.
        # Ports field vocabulary from Legion::LLM::Types::ContentBlock. # -- required for Data.define block scope
        ContentBlock = ::Data.define(
          :type, :text, :data, :source_type, :media_type,
          :detail, :name, :file_id,
          :id, :input, :tool_use_id, :is_error,
          :source, :start_index, :end_index,
          :code, :message, :cache_control, :metadata
        ) do
          # Build from keyword args (primary constructor).
          def self.build(
            type: nil, text: nil, data: nil, source_type: nil, media_type: nil,
            detail: nil, name: nil, file_id: nil,
            id: nil, input: nil, tool_use_id: nil, is_error: nil,
            source: nil, start_index: nil, end_index: nil,
            code: nil, message: nil, cache_control: nil, metadata: {}
          )
            new(
              type: normalize_type!(type, self::BUILD_SITE),
              text:, data:, source_type:, media_type:,
              detail:, name:, file_id:,
              id:, input:, tool_use_id:, is_error:,
              source:, start_index:, end_index:,
              code:, message:, cache_control:,
              metadata: Strict.metadata!(metadata, self::BUILD_SITE)
            )
          end

          # Build from a Hash (raw provider response or deserialized wire payload).
          # Canonical keys only (O03a); unknown keys fold into metadata (L5).
          def self.from_hash(source)
            Strict.require_hash!(source, self::FROM_HASH_SITE)
            hash = Strict.symbolize_keys(source)
            metadata = Strict.fold_unknowns!(self, self::FROM_HASH_SITE, hash)
            build(
              type: hash[:type], text: hash[:text], data: hash[:data],
              source_type: hash[:source_type], media_type: hash[:media_type],
              detail: hash[:detail], name: hash[:name], file_id: hash[:file_id],
              id: hash[:id], input: hash[:input], tool_use_id: hash[:tool_use_id],
              is_error: hash[:is_error], source: hash[:source],
              start_index: hash[:start_index], end_index: hash[:end_index],
              code: hash[:code], message: hash[:message],
              cache_control: hash[:cache_control], metadata:
            )
          end

          # L6: validate against the declared block types when present.
          def self.normalize_type!(type, site)
            return nil if type.nil?

            type_sym = type.is_a?(::String) ? type.to_sym : type
            Strict.enum!(type_sym, self::CONTENT_BLOCK_TYPES, site, :type)
          end

          # Build a text content block.
          def self.text(content, cache_control: nil)
            build(type: :text, text: content, cache_control:)
          end

          # Build a thinking content block.
          def self.thinking(content)
            build(type: :thinking, text: content)
          end

          # Build a tool_use content block.
          def self.tool_use(id:, name:, input:)
            build(type: :tool_use, id:, name:, input:)
          end

          # Build a tool_result content block.
          def self.tool_result(tool_use_id:, content:, is_error: false)
            build(type: :tool_result, text: content, tool_use_id:, is_error:)
          end

          # Build an image content block with media_type (G20a).
          def self.image(data:, media_type:, source_type: :base64, detail: nil)
            build(type: :image, data:, media_type:, source_type:, detail:)
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

          # Human-readable string — prevents #inspect leaking into user-facing output.
          def to_s
            return "[tool_use:#{name}]" if type == :tool_use
            return '[image]' if type == :image

            text.to_s
          end

          # Concise inspect — prevents raw Data.define dump in Array#inspect output.
          def inspect
            "#<ContentBlock:#{type} #{to_s.slice(0, 80).inspect}>"
          end

          # Whether this block carries textual content.
          def text?
            type == :text
          end

          # Whether this block carries thinking/reasoning content.
          def thinking?
            type == :thinking
          end

          # Whether this block represents a tool use request.
          def tool_use?
            type == :tool_use
          end

          # Whether this block represents a tool result.
          def tool_result?
            type == :tool_result
          end
        end

        ContentBlock::CONTENT_BLOCK_TYPES = %i[text thinking tool_use tool_result image audio video].freeze
        ContentBlock::BUILD_SITE = 'Canonical::ContentBlock.build'
        ContentBlock::FROM_HASH_SITE = 'Canonical::ContentBlock.from_hash'
      end
    end
  end
end
# rubocop:enable Metrics/ParameterLists
