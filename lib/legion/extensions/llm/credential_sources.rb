# frozen_string_literal: true

require 'digest'
require 'uri'

module Legion
  module Extensions
    module Llm
      # Read-only helpers that provider gems use to probe common credential
      # locations (env vars, Claude config, Codex auth, Legion settings, and
      # network probes).  All methods are pure readers — the calling provider
      # decides what to do with the result.
      module CredentialSources
        include Legion::Logging::Helper
        extend Legion::Logging::Helper

        CLAUDE_SETTINGS = File.expand_path('~/.claude/settings.json')
        CLAUDE_PROJECT  = File.join(Dir.pwd, '.claude', 'settings.json')
        CODEX_AUTH      = File.expand_path('~/.codex/auth.json')

        # --- public helpers ------------------------------------------------

        # Fetch an environment variable, stripping whitespace.
        # Returns nil when the variable is unset or blank.
        def env(key)
          val = ENV.fetch(key, nil)
          return nil if val.nil?

          stripped = val.strip
          stripped.empty? ? nil : stripped
        end

        # Merged Claude config (user-level + project-level).  Project settings
        # override user settings.  Memoized for the lifetime of the process.
        def claude_config
          @claude_config ||= merge_claude_configs
        end

        # Read a single key from the merged Claude config, trying both symbol
        # and string variants.
        def claude_config_value(key)
          cfg = claude_config
          cfg[key.to_sym] || cfg[key.to_s]
        end

        # Read a key from the :env hash inside Claude config, trying both
        # symbol and string variants.
        def claude_env_value(key)
          env_hash = claude_config_value(:env)
          return nil unless env_hash.is_a?(Hash)

          env_hash[key.to_sym] || env_hash[key.to_s]
        end

        # Read the bearer token from ~/.codex/auth.json when auth_mode is
        # "chatgpt" and the JWT is not expired.
        def codex_token
          data = read_json(CODEX_AUTH)
          mode = data[:auth_mode] || data['auth_mode']
          return nil unless mode == 'chatgpt'

          token = data[:bearer_token] || data['bearer_token']
          return nil if token.nil? || token.to_s.strip.empty?
          return nil unless token_valid?(token)

          token
        end

        # Read the OPENAI_API_KEY from ~/.codex/auth.json.
        def codex_openai_key
          data = read_json(CODEX_AUTH)
          val = data[:OPENAI_API_KEY] || data['OPENAI_API_KEY']
          return nil if val.nil?

          stripped = val.to_s.strip
          stripped.empty? ? nil : stripped
        end

        # Dig into Legion::Settings, returning nil if the module is not loaded
        # or the path doesn't exist.
        def setting(*path)
          return nil unless defined?(::Legion::Settings)

          ::Legion::Settings.dig(*path)
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.credential_sources.setting',
                              path: path.map(&:to_s))
          nil
        end

        # TCP connect probe with a short timeout.  Returns true if the port
        # is reachable, false otherwise.
        def socket_open?(host, port, timeout: 0.1)
          require 'socket'

          addr = Socket.sockaddr_in(port, host)
          sock = Socket.new(Socket::AF_INET, Socket::SOCK_STREAM, 0)
          sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)

          begin
            sock.connect_nonblock(addr)
          rescue IO::WaitWritable
            return false unless sock.wait_writable(timeout)

            begin
              sock.connect_nonblock(addr)
            rescue Errno::EISCONN
              # already connected — success
            end
          end
          true
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.credential_sources.socket_open',
                              host:, port:)
          false
        ensure
          sock&.close
        end

        # HTTP GET probe via Faraday.  Returns true only on a 2xx status.
        def http_ok?(url, path:, timeout: 2)
          require 'faraday'

          conn = Faraday.new(url: url) do |f|
            f.options.timeout = timeout
            f.options.open_timeout = timeout
          end
          response = conn.get(path)
          response.status >= 200 && response.status < 300
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.credential_sources.http_ok',
                              path:)
          false
        ensure
          conn&.close if conn.respond_to?(:close)
        end

        # Deduplicate credential configs by the SHA-256 of their credential
        # value (api_key / bearer_token / access_token).  First source wins.
        # Entries without a credential value are always kept.
        def dedup_credentials(candidates)
          seen = {}
          result = {}

          candidates.each do |instance_id, config|
            hash = credential_hash(config)
            if hash.nil?
              result[instance_id] = config
            elsif !seen.key?(hash)
              seen[hash] = instance_id
              result[instance_id] = config
            end
          end

          result
        end

        # SHA-256 hex digest of the first credential value found in the config
        # hash (checks api_key, bearer_token, access_token in order).
        # Returns nil when no credential field is present.
        def credential_hash(config)
          val = config[:api_key] || config['api_key'] ||
                config[:bearer_token] || config['bearer_token'] ||
                config[:access_token] || config['access_token']
          return nil if val.nil?

          Digest::SHA256.hexdigest(val.to_s)
        end

        # Returns true when the URL points to localhost / 127.0.0.1 / ::1.
        def localhost?(url)
          return false if url.nil?

          uri = URI.parse(url.to_s)
          host = uri.host
          return false if host.nil?

          normalized = host.delete_prefix('[').delete_suffix(']')
          %w[localhost 127.0.0.1 ::1].include?(normalized)
        rescue URI::InvalidURIError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.credential_sources.localhost')
          false
        end

        module_function :env, :claude_config, :claude_config_value,
                        :claude_env_value, :codex_token, :codex_openai_key,
                        :setting, :socket_open?, :http_ok?,
                        :dedup_credentials, :credential_hash, :localhost?

        # --- private helpers -----------------------------------------------

        # Merge user-level (~/.claude/settings.json) and project-level
        # (.claude/settings.json) Claude configs.  Project overrides user.
        def merge_claude_configs
          user = read_json(CLAUDE_SETTINGS)
          project = read_json(CLAUDE_PROJECT)
          deep_merge(user, project)
        end

        # Read and parse a JSON file.  Returns an empty hash on any error.
        def read_json(path)
          return {} unless File.exist?(path)

          raw = File.read(path)
          return {} if raw.strip.empty?

          if defined?(::Legion::JSON)
            ::Legion::JSON.parse(raw, symbolize_names: true)
          else
            ::JSON.parse(raw, symbolize_names: true)
          end
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.credential_sources.read_json',
                              path:)
          {}
        end

        # JWT expiry check.  Decodes the base64 payload segment and checks
        # that exp > now.  Returns true on any parse error (benefit of the
        # doubt).
        def token_valid?(token)
          return true if token.nil?

          require 'base64'
          require 'json'

          parts = token.to_s.split('.')
          return true unless parts.length >= 2

          payload = ::JSON.parse(Base64.urlsafe_decode64(parts[1]))
          exp = payload['exp']
          return true if exp.nil?

          exp.to_i > Time.now.to_i
        rescue StandardError => e
          handle_exception(e, level: :debug, handled: true, operation: 'llm.credential_sources.token_valid')
          true
        end

        # Simple recursive hash merge (project values override user values).
        def deep_merge(base, override)
          base.merge(override) do |_key, old_val, new_val|
            if old_val.is_a?(Hash) && new_val.is_a?(Hash)
              deep_merge(old_val, new_val)
            else
              new_val
            end
          end
        end

        module_function :merge_claude_configs, :read_json,
                        :token_valid?, :deep_merge

        private_class_method :merge_claude_configs, :read_json,
                             :token_valid?, :deep_merge
      end
    end
  end
end
