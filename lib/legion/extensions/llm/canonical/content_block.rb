# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Canonical
        # Typed content block with media_type support per G20a.
        # Ports field vocabulary from Legion::LLM::Types::ContentBlock.
        # rubocop:disable Lint/ConstantDefinitionInBlock -- required for Data.define block scope
        ContentBlock = ::Data.define(
          :type, :text, :data, :source_type, :media_type,
          :detail, :name, :file_id,
          :id, :input, :tool_use_id, :is_error,
          :source, :start_index, :end_index,
          :code, :message, :cache_control
        ) do
          TEXT_TYPE_ALIASES = %i[text output_text input_text].freeze

          # Build a text content block.
          def self.text(content, cache_control: nil)
            new(
              type: :text, text: content, data: nil, source_type: nil, media_type: nil,
              detail: nil, name: nil, file_id: nil, id: nil, input: nil,
              tool_use_id: nil, is_error: nil, source: nil, start_index: nil,
              end_index: nil, code: nil, message: nil, cache_control: cache_control
            )
          end

          # Build a thinking content block.
          def self.thinking(content)
            new(
              type: :thinking, text: content, data: nil, source_type: nil, media_type: nil,
              detail: nil, name: nil, file_id: nil, id: nil, input: nil,
              tool_use_id: nil, is_error: nil, source: nil, start_index: nil,
              end_index: nil, code: nil, message: nil, cache_control: nil
            )
          end

          # Build a tool_use content block.
          def self.tool_use(id:, name:, input:)
            new(
              type: :tool_use, text: nil, data: nil, source_type: nil, media_type: nil,
              detail: nil, name: name, file_id: nil, id: id, input: input,
              tool_use_id: nil, is_error: nil, source: nil, start_index: nil,
              end_index: nil, code: nil, message: nil, cache_control: nil
            )
          end

          # Build a tool_result content block.
          def self.tool_result(tool_use_id:, content:, is_error: false)
            new(
              type: :tool_result, text: content, data: nil, source_type: nil, media_type: nil,
              detail: nil, name: nil, file_id: nil, id: nil, input: nil,
              tool_use_id: tool_use_id, is_error: is_error, source: nil, start_index: nil,
              end_index: nil, code: nil, message: nil, cache_control: nil
            )
          end

          # Build an image content block with media_type (G20a).
          def self.image(data:, media_type:, source_type: :base64, detail: nil)
            new(
              type: :image, text: nil, data: data, source_type: source_type, media_type: media_type,
              detail: detail, name: nil, file_id: nil, id: nil, input: nil,
              tool_use_id: nil, is_error: nil, source: nil, start_index: nil,
              end_index: nil, code: nil, message: nil, cache_control: nil
            )
          end

          # Build from a Hash (raw provider response or deserialized wire payload).
          # Rescues NoMethodError from corrupted inputs (e.g. String elements from
          # prior serialization bugs where ContentBlock#inspect leaked into storage).
          def self.from_hash(source)
            return nil if source.nil?

            h = source.transform_keys(&:to_sym)
            type_raw = h.delete(:type)
            if type_raw
              type_sym = type_raw.to_sym
              h[:type] = TEXT_TYPE_ALIASES.include?(type_sym) ? :text : type_sym
            end

            new(
              type: h[:type],
              text: h[:text],
              data: h[:data],
              source_type: h[:source_type],
              media_type: h[:media_type],
              detail: h[:detail],
              name: h[:name],
              file_id: h[:file_id],
              id: h[:id],
              input: h[:input],
              tool_use_id: h[:tool_use_id],
              is_error: h[:is_error],
              source: h[:source],
              start_index: h[:start_index],
              end_index: h[:end_index],
              code: h[:code],
              message: h[:message],
              cache_control: h[:cache_control]
            )
          rescue NoMethodError => e
            Legion::Logging.log.warn('[canonical][content_block] from_hash received non-Hash input ' \
                                     "(#{source.class}): #{e.message}")
            text(source.to_s)
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
            TEXT_TYPE_ALIASES.include?(type)
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
        # rubocop:enable Lint/ConstantDefinitionInBlock
      end
    end
  end
end
