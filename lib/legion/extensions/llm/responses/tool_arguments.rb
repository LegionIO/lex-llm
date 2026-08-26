# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Responses
        # The ONE shared tool-arguments parser (10 U2). Streaming fragments are
        # assembled into a complete JSON string before parsing; sync providers pass
        # the provider wire string. One strict policy: invalid or non-object JSON
        # raises — corrupted tool arguments never cross the boundary as a
        # fabricated {} (04 L1/L7; the two old rescue-to-{} policies are deleted).
        module ToolArguments
          module_function

          # Parse tool-call arguments into the canonical Hash (10 U2).
          #
          # The provider wire legitimately encodes the arguments in a few
          # forms; this ONE parser maps every legitimate form to the canonical
          # Hash so every lex-llm-* provider parses arguments identically:
          #   - nil, empty/whitespace String, or JSON null  -> {} (no arguments;
          #     documented default, not tolerance)
          #   - an already-decoded wire object (Hash)       -> passed through
          #     (it IS the canonical Hash)
          #   - a JSON-object String                        -> parsed to Hash
          #
          # Genuinely corrupted arguments still raise — a non-object JSON value
          # (array/number/string) or invalid JSON is a contract error, never a
          # fabricated {} (04 L1/L7; the old rescue-to-{} policies are deleted).
          def parse!(raw)
            return {} if raw.nil?
            return raw if raw.is_a?(::Hash)
            return {} if raw.is_a?(::String) && (raw.strip.empty? || raw.strip.casecmp?('null'))

            raise ArgumentError, "tool call arguments expected JSON String or Hash, got #{raw.class}" unless raw.is_a?(::String)

            parsed = ::Legion::JSON.parse(raw, symbolize_names: false)
            return {} if parsed.nil?
            raise ArgumentError, "tool call arguments must be a JSON object, got #{parsed.class}" unless parsed.is_a?(::Hash)

            parsed
          rescue ::Legion::JSON::ParseError => e
            raise ArgumentError, "tool call arguments are not valid JSON: #{e.message}"
          end
        end
      end
    end
  end
end
