# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Handles streaming responses from AI providers.
      module Streaming
        include Legion::Logging::Helper
        extend Legion::Logging::Helper

        module_function

        def stream_response(connection, payload, additional_headers = {}, &block)
          accumulator = StreamAccumulator.new

          response = connection.post stream_url, payload do |req|
            req.headers = additional_headers.merge(req.headers) unless additional_headers.empty?
            on_chunk = build_stream_callback(accumulator, block)
            if Legion::Extensions::Llm.config.log_stream_debug
              log.debug { "Stream callback prepared: #{on_chunk.inspect}" }
            end
            if faraday_1?
              req.options[:on_data] = handle_stream(&on_chunk)
            else
              req.options.on_data = handle_stream(&on_chunk)
            end
          end

          message = accumulator.to_message(response)
          log.debug { "Stream completed: #{message.content}" }
          message
        end

        def build_stream_callback(accumulator, block)
          proc do |chunk|
            accumulator.add chunk
            filtered = accumulator.filtered_chunk(chunk)
            block.call(filtered) if filtered
          end
        end

        def handle_stream(&block)
          build_on_data_handler do |data|
            block.call(build_chunk(data)) if data.is_a?(Hash)
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
          error_data = Legion::JSON.parse(buffer, symbolize_names: false)
          handle_parsed_error(error_data, env)
        rescue Legion::JSON::ParseError
          partial = buffer[/"message"\s*:\s*"([^"]{1,200})/, 1]
          status  = env&.status || 0
          msg     = if partial
                      "Provider error (status #{status}): #{partial}"
                    else
                      "Provider error (status #{status}) — response body incomplete"
                    end
          log.warn "[llm][streaming] action=handle_failed_response status=#{status} " \
                   "partial_body=#{buffer.length}b msg=#{partial.inspect}"
          raise Legion::Extensions::Llm::ServerError, msg
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
          parsed = Legion::JSON.parse(data, symbolize_names: false)
          return parsed unless parsed.is_a?(Hash) && parsed.key?('error')

          handle_parsed_error(parsed, env)
        rescue Legion::JSON::ParseError => e
          handle_exception(e, level: :warn, handled: true, operation: 'llm.streaming.handle_data')
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
          handle_exception(e, level: :warn, handled: true, operation: 'llm.streaming.parse_error_from_json')
        end

        def build_stream_error_response(parsed_data, env, status)
          error_status = status || env&.status || 500

          if faraday_1?
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
              if env&.status == 200
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
