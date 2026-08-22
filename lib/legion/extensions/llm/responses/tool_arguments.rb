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

          # Parse assembled tool-call arguments JSON into a Hash.
          # nil / empty string means "no arguments" and returns {} (documented
          # default, not tolerance).
          def parse!(raw)
            return {} if raw.nil?
            return {} if raw.is_a?(::String) && raw.strip.empty?
            raise ArgumentError, "tool call arguments expected JSON String, got #{raw.class}" unless raw.is_a?(::String)

            parsed = ::Legion::JSON.parse(raw, symbolize_names: false)
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
