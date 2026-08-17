# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      # The shared 3-level settings cascade: provider -> instance -> model,
      # most-specific-first. Single home for resolving operator config
      # (enable_* overrides, weight, preferred_min/max_context_tokens,
      # model_whitelist/blacklist, ...) for a
      # (provider_family, instance, model, key) request.
      #
      # `instance` is the operator's CONFIG NAME — the same identity
      # Identity::InstanceKey#instance_id and the router key settings lookups
      # by — never a derived host:port/credential value.
      #
      # Lookup order (first meaningful value wins):
      #   1. model:    extensions.llm.<provider>.instances.<instance>.models.<model>.<key>
      #                then extensions.llm.<provider>.models.<model>.<key>
      #   2. instance: extensions.llm.<provider>.instances.<instance>.<key>
      #   3. provider: extensions.llm.<provider>.<key>
      #
      # Empty values (nil, blank String, empty Array) never resolve; the
      # cascade falls through to the next scope and returns nil when no scope
      # carries a meaningful value.
      #
      # The cascade READS config only. It never publishes evidence: config and
      # override sources remain unknown-only (Taxonomies::
      # UNKNOWN_ONLY_EVIDENCE_SOURCES), and enable_* overrides are consumed
      # router-side, not published as capability evidence.
      module SettingsCascade
        module_function

        # Resolve `key` for (provider_family, instance, model) from the live
        # Legion::Settings[:extensions][:llm][<provider>] path.
        def resolve(provider_family:, instance:, key:, model: nil)
          text_name!(provider_family, :provider_family)
          text_name!(instance, :instance)
          text_name!(key, :key)
          text_name!(model, :model) if model

          llm_conf = Legion::Settings.dig(:extensions, :llm)
          resolve_from(llm_conf: llm_conf, provider_family: provider_family, instance: instance, key: key, model: model)
        end

        # Resolve against a pre-fetched extensions.llm subtree (plain Hash),
        # e.g. a router settings snapshot. Same cascade as .resolve.
        def resolve_from(llm_conf:, provider_family:, instance:, key:, model: nil)
          text_name!(provider_family, :provider_family)
          text_name!(instance, :instance)
          text_name!(key, :key)

          provider_conf = lookup(llm_conf, provider_family)
          instances = lookup(provider_conf, :instances)
          instance_cfg = lookup(instances, instance)
          resolve_value(provider_conf: provider_conf, instance_cfg: instance_cfg, key: key, model: model)
        end

        # The pure 3-level cascade over pre-fetched scope hashes:
        # model scopes (instance-scoped first, then provider-scoped) > instance
        # > provider. `model: nil` skips the model leg. Returns the first
        # meaningful value or nil.
        def resolve_value(provider_conf:, instance_cfg:, key:, model: nil)
          text_name!(key, :key)
          text_name!(model, :model) if model

          scopes = []
          scopes << model_scope(instance_cfg, model) if model
          scopes << model_scope(provider_conf, model) if model
          scopes << instance_cfg
          scopes << provider_conf

          scopes.each do |scope|
            value = lookup(scope, key)
            return value if meaningful?(value)
          end

          nil
        end

        # The merged model-scope config hash for one model: the provider's
        # models.<model> entry with the instance's models.<model> entry
        # overriding it (the merge the capability feeders use).
        def merge_model_scopes(provider_conf:, instance_cfg:, model:)
          text_name!(model, :model)

          model_scope(provider_conf, model).merge(model_scope(instance_cfg, model))
        end

        def model_scope(scope_conf, model)
          models = lookup(scope_conf, :models)
          return {} unless models.is_a?(::Hash)

          entry = lookup(models, model)
          entry.is_a?(::Hash) ? entry : {}
        end

        def meaningful?(value)
          !value.nil? && !value.to_s.empty? && (!value.is_a?(::Array) || value.any?)
        end

        # Tries the name as-given, as a Symbol, then as a String, preserving
        # meaningful falsy values (false, 0) when the key is present.
        def lookup(scope, name)
          return nil unless scope.is_a?(::Hash)

          return scope[name] if scope.key?(name)
          return scope[name.to_sym] if scope.key?(name.to_sym)

          scope[name.to_s]
        end

        def text_name!(name, field)
          return if name.is_a?(::String) || name.is_a?(::Symbol)

          raise ::ArgumentError, "#{field} must be a String or Symbol"
        end
      end
    end
  end
end
