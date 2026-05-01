# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Global configuration for Legion::Extensions::Llm
      class Configuration
        class << self
          # Declare a single configuration option.
          def option(key, default = nil)
            key = key.to_sym
            return if options.include?(key)

            send(:attr_accessor, key)
            option_keys << key
            defaults[key] = default
          end

          def options
            option_keys.dup
          end

          private

          def option_keys = @option_keys ||= []
          def defaults = @defaults ||= {}
          private :option
        end

        # System-level options are declared here.
        # Provider-specific options are declared in each provider extension via
        # `self.configuration_options`.
        option :default_model, nil
        option :default_embedding_model, nil
        option :default_moderation_model, nil
        option :default_image_model, nil
        option :default_transcription_model, nil

        option :model_registry_file, -> { File.expand_path('models.json', __dir__) }

        option :request_timeout, 300
        option :max_retries, 3
        option :retry_interval, 0.1
        option :retry_backoff_factor, 2
        option :retry_interval_randomness, 0.5
        option :http_proxy, nil

        option :logger, nil
        option :log_file, -> { $stdout }
        option :log_level, -> { ENV['LEGION_LLM_DEBUG'] ? Logger::DEBUG : Logger::INFO }
        option :log_stream_debug, -> { ENV['LEGION_LLM_STREAM_DEBUG'] == 'true' }
        option :log_regexp_timeout, -> { Regexp.respond_to?(:timeout) ? (Regexp.timeout || 1.0) : nil }

        def initialize
          self.class.send(:defaults).each do |key, default|
            value = default.respond_to?(:call) ? instance_exec(&default) : default
            public_send("#{key}=", value)
          end
        end

        def instance_variables
          super.reject { |ivar| ivar.to_s.match?(/_id|_key|_secret|_token$/) }
        end

        def log_regexp_timeout=(value)
          if value.nil?
            @log_regexp_timeout = nil
          elsif Regexp.respond_to?(:timeout)
            @log_regexp_timeout = value
          else
            Legion::Extensions::Llm.logger.warn("log_regexp_timeout is not supported on Ruby #{RUBY_VERSION}")
            @log_regexp_timeout = value
          end
        end
      end
    end
  end
end
