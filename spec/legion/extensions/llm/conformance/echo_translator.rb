# frozen_string_literal: true

# Trivial echo translator for conformance kit self-testing.
# Passes canonical types through unchanged, proving the shared example groups work.

module Canonical
  module Conformance
    # Echo translator: identity transform for both provider and client sides.
    # Used exclusively as a self-test to verify the conformance kit works.
    class EchoTranslator
      def capabilities
        { provider: 'echo', thinking: true, streaming: true, tool_calls: true }
      end

      # Provider translator interface
      def render_request(canonical_request)
        canonical_request.to_h
      end

      def parse_response(wire_hash)
        canonical::Response.from_hash(wire_hash)
      end

      def parse_chunk(raw_chunk)
        canonical::Chunk.from_hash(raw_chunk)
      end

      # Client translator interface
      def format_request(canonical_request)
        canonical_request.to_h
      end

      def parse_request(body, _env = {})
        canonical::Request.from_hash(body)
      end

      def format_response(canonical_response)
        canonical_response.to_h
      end

      def format_chunk(canonical_chunk)
        canonical_chunk.to_h
      end

      def format_error(error, status)
        [status, { error: error.message, type: error.class.name }]
      end

      private

      def canonical
        Legion::Extensions::Llm::Canonical
      end
    end
  end
end
