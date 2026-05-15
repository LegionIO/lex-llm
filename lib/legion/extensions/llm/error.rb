# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Custom error class that wraps API errors from different providers
      # into a consistent format with helpful error messages.
      class Error < StandardError
        attr_reader :response

        def initialize(response = nil, message = nil)
          if response.is_a?(String)
            message = response
            response = nil
          end

          @response = response
          super(message || response&.body)
        end
      end

      # Error classes for non-HTTP errors
      class ConfigurationError < StandardError; end
      class PromptNotFoundError < StandardError; end
      class InvalidRoleError < StandardError; end
      class InvalidToolChoiceError < StandardError; end
      class ModelNotFoundError < StandardError; end
      class UnsupportedAttachmentError < StandardError; end

      # Backward-compatible unsupported-capability error alias.
      class UnsupportedCapabilityError < Errors::UnsupportedCapability
        def initialize(message = nil, provider: nil, capability: nil, model: nil)
          if provider && capability
            super(provider:, capability:, model:)
          else
            @provider = provider
            @capability = capability
            @model = model
            StandardError.instance_method(:initialize).bind_call(self, message)
          end
        end
      end

      # Error classes for different HTTP status codes
      class BadRequestError < Error; end
      class ForbiddenError < Error; end
      class ContextLengthExceededError < Error; end
      class OverloadedError < Error; end
      class PaymentRequiredError < Error; end
      class RateLimitError < Error; end
      class ServerError < Error; end
      class ServiceUnavailableError < Error; end
      class UnauthorizedError < Error; end

      # Faraday middleware that maps provider-specific API errors to Legion::Extensions::Llm errors.
      class ErrorMiddleware < Faraday::Middleware
        STREAM_ERROR_BODY_KEY = :legion_llm_stream_error_body

        def initialize(app, options = {})
          super(app)
          @provider = options[:provider]
        end

        def call(env)
          @app.call(env).on_complete do |response|
            self.class.parse_error(provider: @provider, response: response)
          end
        end

        class << self
          CONTEXT_LENGTH_PATTERNS = [
            /context length/i,
            /context window/i,
            /maximum context/i,
            /request too large/i,
            /too many tokens/i,
            /token count exceeds/i,
            /input[_\s-]?token/i,
            /input or output tokens? must be reduced/i,
            /reduce the length of messages/i
          ].freeze

          def parse_error(provider:, response:) # rubocop:disable Metrics/PerceivedComplexity
            response = response_with_stream_error_body(response)
            message = provider&.parse_error(response)

            case response.status
            when 200..399
              message
            when 400
              if context_length_exceeded?(message)
                raise ContextLengthExceededError.new(response, message || 'Context length exceeded')
              end

              raise BadRequestError.new(response, message || 'Invalid request - please check your input')
            when 401
              raise UnauthorizedError.new(response, message || 'Invalid API key - check your credentials')
            when 402
              raise PaymentRequiredError.new(response, message || 'Payment required - please top up your account')
            when 403
              raise ForbiddenError.new(response,
                                       message || 'Forbidden - you do not have permission to access this resource')
            when 429
              if context_length_exceeded?(message)
                raise ContextLengthExceededError.new(response, message || 'Context length exceeded')
              end

              raise RateLimitError.new(response, message || 'Rate limit exceeded - please wait a moment')
            when 500
              raise ServerError.new(response, message || 'API server error - please try again')
            when 502..504
              raise ServiceUnavailableError.new(response, message || 'API server unavailable - please try again later')
            when 529
              raise OverloadedError.new(response, message || 'Service overloaded - please try again later')
            else
              raise Error.new(response, message || 'An unknown error occurred')
            end
          end

          private

          def response_with_stream_error_body(response)
            return response unless empty_body?(response)

            stream_body = preserved_stream_error_body(response)
            return response if stream_body.to_s.empty?

            ResponseWithBody.new(response, stream_body)
          end

          def empty_body?(response)
            !response.respond_to?(:body) || response.body.to_s.empty?
          end

          def preserved_stream_error_body(response)
            return unless response.respond_to?(:[])

            response[STREAM_ERROR_BODY_KEY]
          rescue StandardError
            nil
          end

          def context_length_exceeded?(message)
            return false if message.to_s.empty?

            CONTEXT_LENGTH_PATTERNS.any? { |pattern| message.match?(pattern) }
          end
        end

        ResponseWithBody = Struct.new(:response, :body) do
          def status = response.status

          def [](key)
            response[key] if response.respond_to?(:[])
          end

          def method_missing(method_name, ...)
            return response.public_send(method_name, ...) if response.respond_to?(method_name)

            super
          end

          def respond_to_missing?(method_name, include_private = false)
            response.respond_to?(method_name, include_private) || super
          end
        end
      end
    end
  end
end

Faraday::Middleware.register_middleware(llm_errors: Legion::Extensions::Llm::ErrorMiddleware)
