# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Fleet
        # Reads fleet settings from Legion::Settings when available, falling back to lex-llm defaults.
        module Settings
          include Legion::Logging::Helper
          extend Legion::Logging::Helper

          module_function

          def value(*path, default:)
            configured_llm_settings.each do |configured|
              found = dig(configured, *path)
              return found unless found.nil?
            end

            fallback = dig(default_settings, *path)
            fallback.nil? ? default : fallback
          end

          def configured_llm_settings
            return [] unless defined?(::Legion::Settings) && ::Legion::Settings.respond_to?(:[])

            configured = []
            extensions = safe_fetch(::Legion::Settings, :extensions)
            extension_llm = dig(extensions, :llm)
            configured << extension_llm if extension_llm.respond_to?(:key?)

            llm = safe_fetch(::Legion::Settings, :llm)
            configured << llm if llm.respond_to?(:key?)
            configured
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'llm.fleet.settings.configured')
            []
          end

          def dig(hash, *keys)
            keys.reduce(hash) do |current, key|
              break nil unless current.respond_to?(:key?)

              symbol_key = key.respond_to?(:to_sym) ? key.to_sym : key
              string_key = key.to_s
              if current.key?(symbol_key)
                current[symbol_key]
              elsif current.key?(string_key)
                current[string_key]
              end
            end
          end

          def safe_fetch(source, key)
            source[key] || source[key.to_s]
          rescue StandardError => e
            handle_exception(e, level: :debug, handled: true, operation: 'llm.fleet.settings.safe_fetch',
                                key: key.to_s)
            nil
          end

          def default_settings
            return ::Legion::Extensions::Llm.default_settings if
              ::Legion::Extensions::Llm.respond_to?(:default_settings)

            {}
          end
        end
      end
    end
  end
end
