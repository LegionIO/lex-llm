# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # Registry of available AI models and their capabilities.
      # H4: the catalog LOOKS UP model facts; it does not choose. There is no
      # cross-provider preference ordering and no arbitrary alias resolution —
      # an ambiguous model id without a provider is a typed error; choosing a
      # provider is the router's job (R4/R7).
      class Models
        include Enumerable

        class << self
          include Legion::Logging::Helper

          # Discover provider classes from the Llm namespace.
          # Each lex-llm-* extension defines a module under Legion::Extensions::Llm
          # that responds to `provider_class` and has a `PROVIDER_FAMILY` constant.
          def scan_provider_classes
            Legion::Extensions::Llm.constants(false).filter_map do |const_name|
              mod = Legion::Extensions::Llm.const_get(const_name, false)
              next unless mod.is_a?(Module) && mod.respond_to?(:provider_class) &&
                          mod.const_defined?(:PROVIDER_FAMILY, false)

              [mod::PROVIDER_FAMILY.to_sym, mod.provider_class]
            end.to_h
          end

          # Resolve a single provider class by slug.
          # Returns nil when the provider is unknown.
          def resolve_provider_class(name)
            return nil if name.nil?

            scan_provider_classes[name.to_sym]
          end

          def instance
            @instance ||= new
          end

          def schema_file
            File.expand_path('models_schema.json', __dir__)
          end

          def load_models(file = Legion::Extensions::Llm.config.model_registry_file)
            read_from_json(file)
          end

          def read_from_json(file = Legion::Extensions::Llm.config.model_registry_file)
            data = File.exist?(file) ? File.read(file) : '[]'
            models = Legion::JSON.parse(data, symbolize_names: true).map { |model| Model::Info.from_hash(model) }
            filter_models(models)
          rescue Legion::JSON::ParseError => e
            handle_exception(e, level: :warn, handled: true, operation: 'llm.models.read_from_json')
            []
          end

          # H4/L8: the catalog is populated from provider fetches (providers
          # publish reality) and the shipped registry file. The third-party
          # models.dev fetch — a hardcoded external URL asserting model facts
          # nobody here owns — is deleted.
          def refresh!(remote_only: false)
            existing_models = load_existing_models

            provider_fetch = fetch_provider_models(remote_only: remote_only)
            log_provider_fetch(provider_fetch)

            merged_models = merge_with_existing(existing_models, provider_fetch)
            @instance = new(merged_models)
          end

          def fetch_provider_models(remote_only: true)
            config = Legion::Extensions::Llm.config
            all_providers = scan_provider_classes.values
            provider_classes = remote_only ? all_providers.reject(&:local?) : all_providers
            configured = provider_classes.select { |klass| klass.configured?(config) }

            result = {
              models: [],
              fetched_providers: [],
              configured_names: configured.map(&:name),
              failed: []
            }

            configured.each do |provider_class|
              result[:models].concat(provider_class.new(config).list_models)
              result[:fetched_providers] << provider_class.slug
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'llm.models.fetch_provider_models')
              result[:failed] << { name: provider_class.name, slug: provider_class.slug, error: e }
            end

            result[:fetched_providers].uniq!
            result
          end

          # Backwards-compatible wrapper used by specs.
          def fetch_from_providers(remote_only: true)
            fetch_provider_models(remote_only: remote_only)[:models]
          end

          # H4: resolve looks an EXISTING model up in the catalog and pairs
          # it with its provider class. The assume_exists branch — which
          # fabricated capability facts (Model::Info.default) for models the
          # system never observed — is deleted: an unknown model is a
          # ModelNotFoundError, full stop.
          def resolve(model_id, provider: nil, config: nil)
            config ||= Legion::Extensions::Llm.config
            model = Models.find(model_id, provider)
            provider_class = resolve_provider_class(model.provider) || raise(Error,
                                                                             "Unknown provider: #{model.provider}")
            [model, provider_class.new(config)]
          end

          def method_missing(method, ...)
            if instance.respond_to?(method)
              instance.send(method, ...)
            else
              super
            end
          end

          def respond_to_missing?(method, include_private = false)
            instance.respond_to?(method, include_private) || super
          end

          def load_existing_models
            existing_models = instance&.all
            existing_models = read_from_json if existing_models.nil? || existing_models.empty?
            existing_models
          end

          def log_provider_fetch(provider_fetch)
            log.info(
              "Fetching models from providers: #{provider_fetch[:configured_names].join(', ')}"
            )
            provider_fetch[:failed].each do |failure|
              log.warn(
                "Failed to fetch #{failure[:name]} models (#{failure[:error].class}: #{failure[:error].message}). " \
                'Keeping existing.'
              )
            end
          end

          # Merge freshly fetched provider models with the existing catalog:
          # a provider that was fetched this cycle replaces its prior entries;
          # providers that were not fetched keep their existing models.
          def merge_with_existing(existing_models, provider_fetch)
            preserved_models = existing_models.group_by(&:provider)
                                              .except(*provider_fetch[:fetched_providers])
                                              .values
                                              .flatten

            provider_models = provider_fetch[:models] + preserved_models
            filter_models(index_by_key(provider_models).values).sort_by { |m| [m.provider.to_s, m.id.to_s] }
          end

          def filter_models(models)
            models.reject do |model|
              model.provider.to_s == 'vertexai' && model.id.to_s.include?('/')
            end
          end

          def index_by_key(models)
            models.to_h do |model|
              ["#{model.provider}:#{model.id}", model]
            end
          end
        end

        def initialize(models = nil)
          @models = self.class.filter_models(models || self.class.load_models)
        end

        def load_from_json!(file = Legion::Extensions::Llm.config.model_registry_file)
          @models = self.class.read_from_json(file)
        end

        def save_to_json(file = Legion::Extensions::Llm.config.model_registry_file)
          File.write(file, Legion::JSON.pretty_generate(all.map(&:to_h)))
        end

        def all
          @models
        end

        def each(&)
          all.each(&)
        end

        def find(model_id, provider = nil)
          if provider
            find_with_provider(model_id, provider)
          else
            find_without_provider(model_id)
          end
        end

        def chat_models
          self.class.new(all.select { |m| m.type == 'chat' })
        end

        def embedding_models
          self.class.new(all.select { |m| m.type == 'embedding' || m.modalities.output.include?('embeddings') })
        end

        def audio_models
          self.class.new(all.select { |m| m.type == 'audio' || m.modalities.output.include?('audio') })
        end

        def image_models
          self.class.new(all.select { |m| m.type == 'image' || m.modalities.output.include?('image') })
        end

        def by_family(family)
          self.class.new(all.select { |m| m.family.to_s == family.to_s })
        end

        def by_provider(provider)
          self.class.new(all.select { |m| m.provider.to_s == provider.to_s })
        end

        def refresh!(remote_only: false)
          self.class.refresh!(remote_only: remote_only)
        end

        def resolve(model_id, provider: nil, config: nil)
          self.class.resolve(model_id, provider: provider, config: config)
        end

        private

        def find_with_provider(model_id, provider)
          resolved_id = provider_resolved_model_id(Aliases.resolve(model_id: model_id, provider: provider), provider)
          all.find { |m| m.id == resolved_id && m.provider.to_s == provider.to_s } ||
            all.find { |m| m.id == model_id && m.provider.to_s == provider.to_s } ||
            raise(ModelNotFoundError, "Unknown model: #{model_id} for provider: #{provider}")
        end

        def provider_resolved_model_id(model_id, provider)
          provider_class = self.class.resolve_provider_class(provider)
          return model_id unless provider_class

          provider_class.resolve_model_id(model_id, config: Legion::Extensions::Llm.config)
        end

        # H4: without a provider, the catalog only accepts a model id that
        # identifies EXACTLY ONE model. An ambiguous id is a typed error —
        # choosing between providers is the router's job, and the arbitrary
        # (values.first) alias resolution is deleted.
        def find_without_provider(model_id)
          exact_matches = all.select { |m| m.id == model_id }
          raise(ModelNotFoundError, "Unknown model: #{model_id}") if exact_matches.empty?

          if exact_matches.size > 1
            providers = exact_matches.map { |m| m.provider.to_s }.uniq.sort
            raise(ArgumentError,
                  "Ambiguous model id: #{model_id} exists for providers #{providers.join(', ')} — " \
                  'pass provider: to Models.find (provider choice belongs to the router)')
          end

          exact_matches.first
        end
      end
    end
  end
end
