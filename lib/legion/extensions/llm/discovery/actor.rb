# frozen_string_literal: true

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

# The base actor inherits the LegionIO time-based Every actor, which only
# exists inside the daemon. In a standalone lex-llm load (specs, gem require)
# Every is absent — define nothing rather than crash. Provider actor files
# carry the same guard.
#
# Like the pipeline, this base lives in `discovery/`, NOT the scanned
# `actors/` dir: a file there would be claimed by the builder as a live
# per-extension actor (and auto-wrapped in a meta actor). A provider's live
# actor is its own `<Provider>::Actor::Discovery` (scanned), which subclasses
# this base with an EMPTY body.
return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module Discovery
        # Base periodic discovery actor for EVERY lex-llm-* provider. This is
        # the interface: a provider subclasses it with an EMPTY body and gets
        # discovery for free —
        #
        #   module Vllm
        #     module Actor
        #       class Discovery < Legion::Extensions::Llm::Discovery::Actor; end
        #     end
        #   end
        #
        # It fires on the configured discovery interval and dispatches each tick
        # to the provider's `Runners::Discovery` module (resolved by convention
        # from this actor's own namespace), which mixes in Discovery::Pipeline
        # and owns the provider-specific fetch/health/evidence/callable. Every
        # generic decision lives in the pipeline; a provider overrides a single
        # method only when its runner lives somewhere non-conventional or its
        # teardown differs.
        #
        # Dispatch contract (Every -> Actors::Base#manual): `use_runner? = false`
        # calls the runner MODULE's `refresh` directly (no Legion::Runner task —
        # the state and the Registry are process-local, so it must run on the
        # owning node); `run_now? = true` fires once on boot then every `time`
        # seconds.
        class Actor < Legion::Extensions::Actors::Every
          include Legion::Extensions::Helpers::Lex

          def run_now?        = true
          def use_runner?     = false
          def runner_function = 'refresh'

          # The provider's discovery runner module, resolved by convention from
          # this actor's namespace: <ProviderModule>::Runners::Discovery. A
          # provider whose runner lives elsewhere overrides this one method.
          def runner_class
            "#{provider_namespace}::Runners::Discovery"
          end

          # Honor the registered discovery interval. A nil TimerTask interval
          # fires once and then stops, so resolve to the registered default
          # (300s) whenever the setting is missing or non-positive.
          def time
            interval = settings.dig(:instances, :default, :discovery_interval)&.to_i ||
                       settings.dig(:discovery, :interval_seconds)&.to_i
            interval&.positive? ? interval : 300
          end

          def shutdown
            Kernel.const_get(runner_class).remove_all_instances
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: "#{provider_slug}.actor.discovery.shutdown")
          end

          private

          # "Legion::Extensions::Llm::Vllm::Actor::Discovery" ->
          # "Legion::Extensions::Llm::Vllm" (drop the trailing Actor::<Name>).
          def provider_namespace
            self.class.name.split('::')[0..-3].join('::')
          end

          def provider_slug
            provider_namespace.split('::').last.to_s.downcase
          end
        end
      end
    end
  end
end
