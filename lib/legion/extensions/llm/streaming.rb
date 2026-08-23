# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Handles streaming responses from AI providers.
      # The provider's build_chunk yields Canonical::Chunk objects; the caller's
      # block receives Canonical::Chunk objects and the sequence ends in exactly
      # one done chunk (or an error chunk followed by the raise, 05 O5).
      # FaradayHandlers / SSE parsing / error paths are unchanged plumbing; the
      # status→error mapping delegates to the ONE mapper (ErrorMiddleware, 10 U8).
      module Streaming
        include Legion::Logging::Helper
        extend Legion::Logging::Helper

        module_function

        def stream_response(connection, payload, additional_headers = {}, model: nil, &block)
          accumulator = StreamAccumulator.new

          begin
            connection.post stream_url, payload do |req|
              req.headers = additional_headers.merge(req.headers) unless additional_headers.empty?
              on_chunk = build_stream_callback(accumulator, block)
              log.debug { "Stream callback prepared: #{on_chunk.inspect}" } if Legion::Extensions::Llm.config.log_stream_debug
              if faraday_1?
                req.options[:on_data] = handle_stream(&on_chunk)
              else
                req.options.on_data = handle_stream(&on_chunk)
              end
            end
          rescue StandardError => e
            block&.call(Canonical::Chunk.error_chunk(error: e, request_id: nil))
            raise
          end

          # Release any text held by the untagged-preamble heuristic so short
          # responses still stream at least one delta to the caller.
          accumulator.flush_pending_chunk.each { |chunk| block&.call(chunk) }

          message = accumulator.to_response(model:)
          log.debug { "Stream completed: #{message.text}" }
          block&.call(Canonical::Chunk.done(request_id: nil, usage: message.usage, stop_reason: message.stop_reason))
          message
        end

        def build_stream_callback(accumulator, block)
          proc do |chunk|
            next unless chunk

            accumulator.add(chunk).each { |emitted| block&.call(emitted) }
          end
        end

        def handle_stream(&block)
          build_on_data_handler do |data|
            next unless data.is_a?(Hash)

            result = build_chunk(data)
            next unless result

            if result.is_a?(Array)
              result.each { |chunk| block.call(chunk) if chunk }
            else
              block.call(result)
            end
          end
        end

        private

        def faraday_1?
          Faraday::VERSION.start_with?('1')
        end

        def build_on_data_handler(&)
          buffer = +''
          parser = EventStreamParser::Parser.new

          FaradayHandlers.build(
            faraday_v1: faraday_1?,
            on_chunk: ->(chunk, env) { process_stream_chunk(chunk, parser, env, &) },
            on_failed_response: ->(chunk, env) { handle_failed_response(chunk, buffer, env) }
          )
        end

        def process_stream_chunk(chunk, parser, env, &)
          log.debug { "Received chunk: #{chunk}" } if Legion::Extensions::Llm.config.log_stream_debug

          if error_chunk?(chunk)
            handle_error_chunk(chunk, env)
          elsif json_error_payload?(chunk)
            handle_json_error_chunk(chunk, env)
          else
            yield handle_sse(chunk, parser, env, &)
          end
        end

        def error_chunk?(chunk)
          chunk.start_with?('event: error')
        end

        def json_error_payload?(chunk)
          chunk.lstrip.start_with?('{') && chunk.include?('"error"')
        end

        def handle_json_error_chunk(chunk, env)
          parse_error_from_json(chunk, env, 'Failed to parse JSON error chunk')
        end

        def handle_error_chunk(chunk, env)
          error_data = chunk.split("\n")[1].delete_prefix('data: ')
          parse_error_from_json(error_data, env, 'Failed to parse error chunk')
        end

        def handle_failed_response(chunk, buffer, env)
          buffer << chunk
          body_persisted = persist_failed_response_body(buffer, env)
          error_data = Legion::JSON.parse(buffer, symbolize_names: false)
          handle_parsed_error(error_data, env)
        rescue Legion::JSON::ParseError
          return if body_persisted

          raise_partial_streaming_error(buffer, env)
        end

        def persist_failed_response_body(buffer, env)
          custom_persisted = persist_failed_response_custom_body?(buffer, env)
          body_persisted = persist_failed_response_env_body?(buffer, env)
          custom_persisted || body_persisted
        end

        def persist_failed_response_env_body?(buffer, env)
          return false unless env.respond_to?(:body=)

          env.body = buffer.dup
          true
        end

        def persist_failed_response_custom_body?(buffer, env)
          return false unless env.respond_to?(:[]=)

          env[ErrorMiddleware::STREAM_ERROR_BODY_KEY] = buffer.dup
          true
        rescue StandardError
          false
        end

        def raise_partial_streaming_error(buffer, env)
          partial = buffer[/"message"\s*:\s*"([^"]{1,200})/, 1]
          status  = env&.status || 0
          msg     = if partial
                      "Provider error (status #{status}): #{partial}"
                    else
                      "Provider error (status #{status}) - response body incomplete"
                    end
          log.warn "[llm][streaming] action=handle_failed_response status=#{status} " \
                   "partial_body=#{buffer.length}b msg=#{partial.inspect}"
          raise_streaming_status_error(status, msg)
        end

        # 10 U8: the streaming path delegates to the ONE status→error mapper
        # (ErrorMiddleware.parse_error) — the inlined case table is deleted.
        # The provider's parse_error extracts the message from the synthesized
        # body.
        def raise_streaming_status_error(status, message)
          response = Struct.new(:body, :status).new({ 'error' => { 'message' => message } }, status)
          ErrorMiddleware.parse_error(provider: respond_to?(:parse_error) ? self : nil, response:)
        end

        def handle_sse(chunk, parser, env, &)
          parser.feed(chunk) do |type, data|
            case type.to_sym
            when :error
              handle_error_event(data, env)
            else
              yield handle_data(data, env, &) unless data == '[DONE]'
            end
          end
        end

        def handle_data(data, env)
          # An empty data frame carries nothing — it is not a parse failure.
          return if data.to_s.strip.empty?

          parsed = Legion::JSON.parse(data, symbolize_names: false)
          return parsed unless parsed.is_a?(Hash) && parsed.key?('error')

          handle_parsed_error(parsed, env)
        rescue Legion::JSON::ParseError => e
          # M1: an unparseable mid-stream data frame is still a provider
          # error — a classified failure through the one mapper, never a
          # silent drop (the stream must not complete "successfully").
          handle_exception(e, level: :warn, handled: true, operation: 'llm.streaming.handle_data')
          raise_unparseable_streaming_error(env, data, 'data frame')
        end

        def handle_error_event(data, env)
          parse_error_from_json(data, env, 'Failed to parse error event')
        end

        def parse_streaming_error(data)
          error_data = Legion::JSON.parse(data, symbolize_names: false)
          [500, error_data['message'] || 'Unknown streaming error']
        rescue Legion::JSON::ParseError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.streaming.parse_streaming_error')
          [500, "Failed to parse error: #{data}"]
        end

        def handle_parsed_error(parsed_data, env)
          status, _message = parse_streaming_error(parsed_data.to_json)
          error_response = build_stream_error_response(parsed_data, env, status)
          ErrorMiddleware.parse_error(provider: self, response: error_response)
        end

        def parse_error_from_json(data, env, _error_message)
          parsed_data = Legion::JSON.parse(data, symbolize_names: false)
          handle_parsed_error(parsed_data, env)
        rescue Legion::JSON::ParseError => e
          # M1: an error event that cannot be parsed is STILL an error event
          # — a classified failure, never a silent nil (the pre-M1 fail-open
          # completed the stream "successfully" on the provider's explicit
          # error signal).
          handle_exception(e, level: :warn, handled: true, operation: 'llm.streaming.parse_error_from_json')
          raise_unparseable_streaming_error(env, data, 'error event')
        end

        # One classified failure for unparseable stream error content — the
        # same 500 classification the PARSEABLE in-band error path uses
        # (parse_streaming_error): an in-band provider error event is a
        # failure regardless of the stream's HTTP status. The raw payload is
        # bounded (200 chars) — never the full body.
        def raise_unparseable_streaming_error(_env, data, kind)
          raise_streaming_status_error(500, "Provider error: unparseable #{kind} (#{data.to_s[0, 200].inspect})")
        end

        def build_stream_error_response(parsed_data, env, status)
          error_status = status || env&.status || 500

          if faraday_1? || env.nil?
            Struct.new(:body, :status).new(parsed_data, error_status)
          else
            env.merge(body: parsed_data, status: error_status)
          end
        end

        # Builds Faraday on_data handlers for different major versions.
        module FaradayHandlers
          module_function

          def build(faraday_v1:, on_chunk:, on_failed_response:)
            if faraday_v1
              v1_on_data(on_chunk)
            else
              v2_on_data(on_chunk, on_failed_response)
            end
          end

          def v1_on_data(on_chunk)
            proc do |chunk, _size|
              on_chunk.call(chunk, nil)
            end
          end

          def v2_on_data(on_chunk, on_failed_response)
            proc do |chunk, _bytes, env|
              # Typhoeus/libcurl sends on_data callbacks before headers arrive, so env&.status
              # may be nil or 0 during streaming. Only treat as failure when we have a
              # definitive non-200 status (e.g. 400, 500) and still have data to process.
              status = env&.status
              if status == 200 || status.nil? || status.zero?
                on_chunk.call(chunk, env)
              else
                on_failed_response.call(chunk, env)
              end
            end
          end
        end
      end
    end
  end
end
