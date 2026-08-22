# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Global configuration for Legion::Extensions::Llm
      class Configuration
        include Legion::Logging::Helper

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

          def register_provider_options(keys)
            Array(keys).each { |key| option(key.to_sym) }
          end

          include Legion::Logging::Helper

          # L5: the log defaults, read from the settings system (the ENV
          # reads are deleted). A configured log_level Symbol/String names a
          # Logger constant — an unknown name is a configuration error (it
          # raises, it does not fall back).
          def log_settings_defaults
            {
              level: log_level_value(llm_setting(:log_level)),
              stream_debug: llm_setting(:log_stream_debug) == true
            }
          end

          private

          def option_keys = @option_keys ||= []
          def defaults = @defaults ||= {}

          def log_level_value(value)
            return Logger::INFO if value.nil?

            value.is_a?(::Integer) ? value : Logger.const_get(value.to_s.upcase)
          end

          def llm_setting(key)
            return nil unless defined?(::Legion::Settings) && ::Legion::Settings.respond_to?(:dig)

            ::Legion::Settings.dig(:extensions, :llm, key)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.configuration.setting', key:)
            nil
          end
          private :option, :log_level_value, :llm_setting
        end

        # System-level options are declared here.
        # Provider-specific options are declared in each provider extension via
        # `self.configuration_options`.
        # H4: the dormant default_model / default_*_model options are deleted —
        # a model-defaulting authority with no consumer (verified in-repo and
        # in consumer gems). Model selection belongs to the router.

        option :model_registry_file, -> { File.expand_path('models.json', __dir__) }

        option :request_timeout, 300
        option :max_retries, 3
        option :retry_interval, 0.1
        option :retry_backoff_factor, 2
        option :retry_interval_randomness, 0.5
        option :http_proxy, nil

        option :logger, nil
        option :log_file, -> { $stdout }
        # L5: the ENV reads (LEGION_LLM_DEBUG / LEGION_LLM_STREAM_DEBUG) are
        # deleted — every tunable lives in the settings system:
        # extensions.llm.log_level (Symbol/Integer; Logger::INFO when unset)
        # and extensions.llm.log_stream_debug (boolean; false when unset).
        option :log_level, -> { self.class.log_settings_defaults[:level] }
        option :log_stream_debug, -> { self.class.log_settings_defaults[:stream_debug] }
        option :log_regexp_timeout, -> { Regexp.respond_to?(:timeout) ? (Regexp.timeout || 1.0) : nil }

        # Prompt caching
        option :llm_cache_enabled, true
        option :cache_control_prefix_tokens, 4

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
            log.warn { "log_regexp_timeout is not supported on Ruby #{RUBY_VERSION}" }
            @log_regexp_timeout = value
          end
        end
      end
    end
  end
end
