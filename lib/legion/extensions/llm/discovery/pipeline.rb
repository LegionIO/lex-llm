# frozen_string_literal: true

require 'concurrent'
require 'uri'
require 'digest'
require 'faraday'

require 'legion/logging'
require 'legion/json'
require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/inventory/weight_reconciler'

module Legion
  module Extensions
    module Llm
      module Discovery
        # The shared discovery pipeline for EVERY lex-llm-* provider — the write
        # half of the inventory interface. A provider mixes it into its own
        # `<Provider>::Runners::Discovery` module and overrides ONLY the
        # genuinely provider-specific methods (fetch_raw_models, check_health,
        # build_offering_draft, build_callable, and — if its config keys differ —
        # catalog_base_url / auth_token / derive_physical_id). Everything else
        # (reconcile, claim, activate, probe, replace, weight publication, health
        # display, dormant weight tracking) is inherited.
        #
        #   module Vllm
        #     module Runners
        #       module Discovery
        #         extend self
        #         include Legion::Extensions::Llm::Discovery::Pipeline
        #         def fetch_raw_models(instance_cfg:) = ...
        #         def build_offering_draft(...)       = ...
        #         def build_callable(instance_cfg:)   = ...
        #       end
        #     end
        #   end
        #
        # It is a STATELESS module in the LegionIO sense: it is not itself a live
        # runner and it lives OUTSIDE the framework-scanned `runners/` dir (a
        # base in that dir is claimed by the builder as a live per-extension
        # runner). Each provider's `<Provider>::Runners::Discovery` is the live,
        # scanned runner; it is that module object which carries the per-instance
        # working state (`states` — the claim handles + last built drafts +
        # publish progress), one per provider. That state is the writer's working
        # state, NOT a second inventory: the Inventory::Registry remains the
        # single source of truth.
        #
        # The base actor (`Discovery::Actor`) fires on the discovery interval and
        # dispatches `runner_class.refresh` each tick (manual, in-process — the
        # state and the Registry are both process-local, so the pipeline must run
        # on the owning node, not as a remote Runner task).
        #
        # WEIGHT IS NOT COMPUTED HERE. Drafts are built identity-weighted;
        # Inventory::WeightReconciler recomputes the write-time weight from live
        # settings at publish (commit/activate). One weight owner, no duplication.
        module Pipeline
          include Legion::Extensions::Helpers::Lex

          # A failed catalog fetch is not a catalog fact: keep the last good
          # snapshot rather than evaporating a live instance's lanes for a cycle.
          class CatalogFetchFailure < StandardError; end

          # Per-provider working state, carried by the including runner module
          # (one per provider). Lazy module-ivar accessors — a module has no
          # constructor. The Inventory::Registry is the source of truth; this is
          # only the writer's in-flight working state for this provider.
          def states
            @states ||= Concurrent::Map.new
          end

          def state_mutex
            @state_mutex ||= Mutex.new
          end

          def dormant_weight_tracker
            @dormant_weight_tracker ||= Legion::Extensions::Llm::Inventory::DormantWeightTracker.new
          end

          # Test hook: drop this provider's working state for a fresh run.
          def reset_state!
            @states = nil
            @dormant_weight_tracker = nil
          end

          # ── Provider-specific hooks (override in the provider's runner) ─────

          # Return an Array of raw model Hashes for this instance. Default is the
          # OpenAI-compatible GET /v1/models -> body[:data]. A non-OpenAI provider
          # overrides this entirely.
          def fetch_raw_models(instance_cfg:)
            conn = build_connection(base_url: catalog_base_url(instance_cfg: instance_cfg), instance_cfg: instance_cfg, timeout: 15, open_timeout: 5)
            response = conn.get(models_path)
            raise CatalogFetchFailure, "catalog fetch returned HTTP #{response.status}" unless response.status.between?(200, 299)

            Array(Legion::JSON.load(response.body).fetch(:data, []))
          end

          # The model's stable id within the catalog list. OpenAI-compatible
          # /v1/models lists carry it under :id; Ollama's /api/tags carries it
          # under :name.
          def model_id_from(model_data)
            model_data[:id].to_s
          end

          # Return an Inventory::ReadinessResult. Default is the OpenAI-compatible
          # GET /health. A provider with a different readiness probe overrides it.
          def check_health(instance_cfg:)
            conn = build_connection(base_url: catalog_base_url(instance_cfg: instance_cfg), instance_cfg: instance_cfg, timeout: 5, open_timeout: 3)
            response = conn.get(health_path)
            Legion::Extensions::Llm::Inventory::ReadinessResult.new(
              ready: response.status == 200, reason: "#{health_path} returned #{response.status}",
              metadata: { status: response.status }
            )
          rescue Faraday::ConnectionFailed => e
            handle_exception(e, level: :warn, handled: true, operation: "#{provider_family}.runner.discovery.health")
            readiness_failure(error: e)
          rescue StandardError => e
            raise e if discovery_programming_error?(e)

            handle_exception(e, level: :warn, handled: true, operation: "#{provider_family}.runner.discovery.health")
            readiness_failure(error: e)
          end

          # Build the Inventory::OfferingDraft (evidence + metadata) for one model.
          # NO weight — the reconciler computes it at publish. Abstract: a provider
          # MUST implement its capability/operation evidence knowledge.
          def build_offering_draft(instance_cfg:, instance_key:, model_id:, model_data:)
            raise NotImplementedError, "#{name} must implement #build_offering_draft"
          end

          # Build the provider's inference callable captured into the registry.
          # Abstract: a provider MUST implement how it executes inference.
          def build_callable(instance_cfg:)
            raise NotImplementedError, "#{name} must implement #build_callable"
          end

          # OpenAI-compatible defaults — overridable per provider.
          def models_path = '/v1/models'
          def health_path = '/health'

          def catalog_base_url(instance_cfg:)
            normalize_api_base(instance_cfg[:base_url] || instance_cfg[:endpoint])
          end

          def auth_token(instance_cfg:)
            token = instance_cfg.dig(:credentials, :api_key) || instance_cfg[:api_key]
            token if token.is_a?(String) && !token.strip.empty?
          end

          # ── Entrypoint (called by the actor's manual dispatch) ───────────────

          def refresh(**)
            reconcile_instances
            { success: true }
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: "#{provider_family}.runner.discovery.refresh")
            { success: false }
          end

          def remove_all_instances(**)
            tracked = state_mutex.synchronize { states.keys }
            tracked.each { |instance_id| remove_instance_state(instance_id) }
            state_mutex.synchronize do
              states.clear
              dormant_weight_tracker.clear!
            end
            { success: true }
          end

          # ── Provider family / module / instance catalog ─────────────────────

          # Resolved from the INCLUDING runner module's own name, because the
          # pipeline is a mixed-in module: here `self` IS the provider's
          # <Provider>::Runners::Discovery module (a Module), so its name is
          # `self.name`, not `self.class.name`.
          # "Legion::Extensions::Llm::Vllm::Runners::Discovery" -> "Legion::Extensions::Llm::Vllm"
          def provider_namespace
            @provider_namespace ||= name.split('::')[0..-3].join('::')
          end

          def provider_family
            @provider_family ||= provider_namespace.split('::').last.to_s.downcase.to_sym
          end

          def provider_module
            @provider_module ||= Kernel.const_get(provider_namespace)
          end

          # The provider module's public instance catalog — the single source of
          # configured instances, shared with the dispatch path (legion-llm
          # Call::Providers reads the same method). A provider that defines no
          # discover_instances does not populate the inventory.
          def discover_instances
            return {} unless provider_module.respond_to?(:discover_instances)

            provider_module.discover_instances
          end

          # ── Reconcile (each tick) ───────────────────────────────────────────

          def reconcile_instances
            configured = discover_instances
            configured_ids = configured.keys.map(&:to_s)

            tracked_ids = state_mutex.synchronize { states.keys }
            tracked_ids.each do |instance_id|
              remove_instance_state(instance_id) unless configured_ids.include?(instance_id)
            end

            configured.each do |name, instance_cfg|
              update_instance(name: name.to_s, instance_cfg: instance_cfg)
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: "#{provider_family}.runner.discovery.instance", instance_name: name.to_s)
            end
            observe_dormant_weights
          end

          def update_instance(name:, instance_cfg:)
            state = state_mutex.synchronize { states[name] }
            if state && physical_id_changed?(state, instance_cfg)
              remove_instance_state(name)
              claim_and_activate_instance(name: name, instance_cfg: instance_cfg)
            elsif state
              refresh_instance(instance_id: name, instance_cfg: instance_cfg)
            else
              claim_and_activate_instance(name: name, instance_cfg: instance_cfg)
            end
          end

          def physical_id_changed?(state, instance_cfg)
            state[:instance_key].physical_id != derive_physical_id(instance_cfg: instance_cfg)
          end

          def remove_instance_state(instance_id)
            state = state_mutex.synchronize do
              tracked = states[instance_id]
              next unless tracked

              publisher.remove_instance(instance_id: instance_id, publisher_token: tracked[:publisher_token])
              states.delete(instance_id) if states[instance_id].equal?(tracked)
              tracked
            end
            return unless state

            clear_settings_health(name: state[:name])
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: "#{provider_family}.runner.discovery.remove_instance", instance_id: instance_id)
          end

          # ── Claim / activate ────────────────────────────────────────────────

          def publisher
            @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: provider_family)
          end

          def claim_and_activate_instance(name:, instance_cfg:)
            instance_id = name.to_s
            instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
              provider_family: provider_family, instance_id: instance_id,
              physical_id: derive_physical_id(instance_cfg: instance_cfg)
            )
            begin
              offerings = build_offerings(instance_cfg: instance_cfg, instance_key: instance_key)
            rescue CatalogFetchFailure
              log.debug { "#{provider_family} discovery: catalog fetch failed at claim for #{instance_id} — deferring readiness" }
              offerings = nil
            end
            callable = build_callable(instance_cfg: instance_cfg)
            probe_coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
              instance_key: instance_key, enqueue: build_probe_enqueue(instance_id: instance_id)
            )
            publisher_token = publisher.claim_instance(
              instance_id: instance_id, physical_id: instance_key.physical_id,
              callable: callable, probe_request_handle: probe_coordinator
            )
            state = {
              name: instance_id, instance_key: instance_key, instance_cfg: instance_cfg,
              callable: callable, probe_coordinator: probe_coordinator,
              publisher_token: publisher_token, sequence: 0, offerings: offerings || []
            }
            Legion::Extensions::Llm::Inventory::WeightReconciler.track_initializing!(
              states: states, state_key: instance_id, state: state, mutex: state_mutex
            )
            perform_readiness(instance_id: instance_id, state: state, offerings: offerings) if offerings
          end

          def perform_readiness(instance_id:, state:, offerings:)
            reconcile_weight_snapshot(instance_id: instance_id, state: state, discovered_offerings: offerings)
            probe_token = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: state[:publisher_token])
            readiness = check_health(instance_cfg: state[:instance_cfg])
            report_probe_result(instance_id: instance_id, state: state, probe_token: probe_token, readiness: readiness)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: "#{provider_family}.runner.discovery.readiness", instance_id: instance_id)
          end

          def report_probe_result(instance_id:, state:, probe_token:, readiness:)
            committed = if readiness.ready? && tracked_unpublished?(instance_id: instance_id, state: state)
                          activate_tracked_state(instance_id: instance_id, state: state, probe_token: probe_token)
                        else
                          report_tracked_readiness(instance_id: instance_id, state: state, probe_token: probe_token, readiness: readiness)
                        end
            write_instance_health(state) if committed
            committed
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: "#{provider_family}.runner.discovery.report_probe", instance_id: instance_id)
            false
          end

          def tracked_unpublished?(instance_id:, state:)
            state_mutex.synchronize { states[instance_id].equal?(state) && !state.fetch(:published) }
          end

          def report_tracked_readiness(instance_id:, state:, probe_token:, readiness:)
            state_mutex.synchronize do
              return false unless states[instance_id].equal?(state)

              if readiness.ready?
                publisher.readiness_succeeded(instance_id: instance_id, probe_token: probe_token)
              else
                publisher.readiness_failed(instance_id: instance_id, probe_token: probe_token, reason: readiness.reason)
              end
              true
            end
          end

          # ── Probe (refresh path) ────────────────────────────────────────────

          def refresh_instance(instance_id:, instance_cfg:)
            state = state_mutex.synchronize { states[instance_id] }
            return unless state

            status = publisher.snapshot.publication_status(instance_key: state[:instance_key])
            if status.state == :initializing
              begin
                offerings = build_offerings(instance_cfg: instance_cfg, instance_key: state[:instance_key])
              rescue CatalogFetchFailure
                log.debug { "#{provider_family} discovery: catalog fetch failed for #{instance_id} — staying :initializing" }
                return
              end
              perform_readiness(instance_id: instance_id, state: state, offerings: offerings)
              return
            end

            replace_if_changed(instance_id: instance_id, state: state, instance_cfg: instance_cfg)
            run_cadence_probe(instance_id: instance_id, state: state)
          end

          def replace_if_changed(instance_id:, state:, instance_cfg:)
            begin
              new_offerings = build_offerings(instance_cfg: instance_cfg, instance_key: state[:instance_key])
            rescue CatalogFetchFailure
              log.debug { "#{provider_family} discovery: catalog fetch failed for #{instance_id} — keeping last snapshot" }
              return
            end
            changed = reconcile_weight_snapshot(instance_id: instance_id, state: state, discovered_offerings: new_offerings)
            write_instance_health(state) if changed
          end

          def run_cadence_probe(instance_id:, state:)
            coordinator = state[:probe_coordinator]
            return unless coordinator.begin_probe

            probe_token = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: state[:publisher_token])
            readiness = check_health(instance_cfg: state[:instance_cfg])
            coordinator.finish_probe
            report_probe_result(instance_id: instance_id, state: state, probe_token: probe_token, readiness: readiness)
          rescue StandardError => e
            finish_probe_safely(coordinator)
            handle_exception(e, level: :warn, operation: "#{provider_family}.runner.discovery.cadence_probe", instance_id: instance_id)
          end

          def handle_reactive_probe(instance_id:, request:)
            state = state_mutex.synchronize { states[instance_id] }
            return unless state

            coordinator = state[:probe_coordinator]
            return unless coordinator.begin_probe(request: request)

            probe_token = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: state[:publisher_token])
            readiness = check_health(instance_cfg: state[:instance_cfg])
            coordinator.finish_probe(request: request)
            report_probe_result(instance_id: instance_id, state: state, probe_token: probe_token, readiness: readiness)
          rescue StandardError => e
            begin
              coordinator.finish_probe(request: request)
            rescue StandardError => finish_e
              handle_exception(finish_e, level: :warn, handled: true, operation: "#{provider_family}.runner.discovery.reactive_probe.finish", instance_id: instance_id)
            end
            handle_exception(e, level: :warn, operation: "#{provider_family}.runner.discovery.reactive_probe", instance_id: instance_id)
          end

          def build_probe_enqueue(instance_id:)
            proc do |request:|
              handle_reactive_probe(instance_id: instance_id, request: request)
              true
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: "#{provider_family}.runner.discovery.probe_enqueue", instance_id: instance_id)
              false
            end
          end

          # ── Weight publication (delegates to the shared reconciler) ─────────

          def reconcile_weight_snapshot(instance_id:, state:, discovered_offerings:)
            Legion::Extensions::Llm::Inventory::WeightReconciler.commit_if_changed!(
              settings: Legion::Settings, instance_id: instance_id, state: state,
              discovered_offerings: discovered_offerings, mutex: state_mutex,
              equivalent: lambda do |previous, current|
                !states[instance_id].equal?(state) || offerings_equivalent?(previous, current)
              end,
              replace: method(:replace_weight_snapshot)
            )
          end

          def replace_weight_snapshot(instance_id:, state:, offerings:, sequence:)
            publisher.replace_instance_snapshot(
              instance_id: instance_id, publisher_token: state.fetch(:publisher_token),
              offerings: offerings, sequence: sequence
            )
          end

          def activate_weight_snapshot(instance_id:, state:, offerings:, sequence:, probe_token:)
            publisher.activate_instance_snapshot(
              instance_id: instance_id, publisher_token: state.fetch(:publisher_token),
              offerings: offerings, sequence: sequence, probe_token: probe_token
            )
          end

          def activate_tracked_state(instance_id:, state:, probe_token:)
            Legion::Extensions::Llm::Inventory::WeightReconciler.activate_tracked!(
              settings: Legion::Settings, instance_id: instance_id, state_key: state.fetch(:name),
              state: state, states: states, mutex: state_mutex, probe_token: probe_token,
              activate: method(:activate_weight_snapshot),
              activation_sequence: ->(tracked) { tracked.fetch(:sequence) }
            )
          end

          def observe_dormant_weights
            Legion::Extensions::Llm::Inventory::WeightReconciler.observe_dormant!(
              settings: Legion::Settings, provider_family: provider_family, states: states,
              mutex: state_mutex, tracker: dormant_weight_tracker,
              dormant_logger: ->(key) { log.info("[llm][#{provider_family}] action=dormant_weight weight_key=#{key.inspect} no_lane_published=true") }
            )
          end

          # ── Offering build (weight-free draft; reconciler weights at publish) ─

          def build_offerings(instance_cfg:, instance_key:)
            models = fetch_raw_models(instance_cfg: instance_cfg)
            models.filter_map do |model_data|
              model_id = model_id_from(model_data)
              next if model_id.empty?

              build_offering_draft(instance_cfg: instance_cfg, instance_key: instance_key, model_id: model_id, model_data: model_data)
            end
          rescue StandardError => e
            raise e if discovery_programming_error?(e)
            raise e if e.is_a?(CatalogFetchFailure)

            handle_exception(e, level: :warn, handled: false, operation: "#{provider_family}.runner.discovery.build_offerings")
            raise CatalogFetchFailure, "catalog build failed (#{e.class.name})", cause: e
          end

          # A programming bug in discovery must fail loud — swallowing it publishes
          # ZERO offerings and makes an activated instance invisible.
          def discovery_programming_error?(error)
            error.is_a?(NameError) || error.is_a?(ArgumentError)
          end

          def offerings_equivalent?(previous, current)
            offering_comparison_multiset(previous) == offering_comparison_multiset(current)
          end

          # ── Health display (write-back to settings, post-commit) ────────────

          def write_instance_health(state)
            instance_key = state[:instance_key]
            snapshot = publisher.snapshot
            display = display_fact(instance_key: instance_key, snapshot: snapshot)

            instance_settings = settings.dig(:instances, state[:name].to_sym)
            return unless instance_settings.is_a?(Hash)

            instance_settings[:health] = health_hash(display)
            instance_settings[:capabilities] = union_capabilities(instance_key)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: "#{provider_family}.runner.discovery.write_health", instance_id: state[:instance_key].instance_id)
          end

          def clear_settings_health(name:)
            instance_settings = settings.dig(:instances, name.to_sym)
            return unless instance_settings.is_a?(Hash)

            instance_settings.delete(:health)
            instance_settings.delete(:capabilities)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: "#{provider_family}.runner.discovery.clear_health", instance_name: name.to_s)
          end

          def union_capabilities(instance_key)
            capabilities = Set.new
            publisher.snapshot.lanes_for(instance_key: instance_key).each do |lane|
              lane.capability_evidence.each do |capability, evidence|
                capabilities << capability if evidence.supported?
              end
            end
            capabilities.to_a.sort
          end

          # ── Physical identity (secondary; dedup/diagnostics only) ───────────

          def derive_physical_id(instance_cfg:)
            host_port = extract_host_port(url: catalog_base_url(instance_cfg: instance_cfg))
            token = auth_token(instance_cfg: instance_cfg)
            return "#{host_port}/ak:#{::Digest::SHA256.hexdigest(token)[0, 6]}" if token

            host_port
          end

          private

          def offering_comparison_multiset(offerings)
            Array(offerings).map { |draft| offering_comparison_state(draft) }.tally
          end

          def offering_comparison_state(draft)
            state = draft.to_h
            state[:operation_evidence] = comparison_evidence_map(draft.operation_evidence)
            state[:capability_evidence] = comparison_evidence_map(draft.capability_evidence)
            %i[context_evidence max_output_evidence embedding_dimensions_evidence model_revision_evidence tokenizer_evidence].each do |field|
              state[field] = draft.public_send(field).to_h.except(:observed_at)
            end
            state
          end

          def comparison_evidence_map(evidence)
            evidence.transform_values { |entry| entry.to_h.except(:observed_at) }
          end

          def display_fact(instance_key:, snapshot:)
            record = snapshot.instance(instance_key: instance_key)
            if record
              fact = record.availability
              return { state: fact.state, reason: fact.reason, observed_at: fact.observed_at, last_probe_outcome: fact.last_probe_outcome, source: fact.source }
            end

            status = snapshot.publication_status(instance_key: instance_key)
            { state: :initializing, reason: status.last_error || 'instance initializing', observed_at: status.last_probe_completed_at, last_probe_outcome: status.last_probe_outcome,
              source: :startup_readiness }
          end

          def health_hash(fact)
            { state: fact[:state], reason: fact[:reason], observed_at: fact[:observed_at]&.iso8601, last_probe_outcome: fact[:last_probe_outcome], source: fact[:source] }
          end

          def readiness_failure(error:)
            Legion::Extensions::Llm::Inventory::ReadinessResult.new(
              ready: false, reason: "#{health_path} failed (#{error.class.name})", metadata: { error_class: error.class.name }
            )
          end

          def normalize_api_base(url)
            url.to_s.sub(%r{/v1/?\z}, '')
          end

          def extract_host_port(url:)
            uri = URI.parse(url.to_s)
            "#{uri.host || 'localhost'}:#{uri.port}"
          rescue URI::InvalidURIError => e
            handle_exception(e, level: :warn, handled: true, operation: "#{provider_family}.runner.discovery.extract_host_port", url: url.to_s)
            raise
          end

          def build_connection(base_url:, instance_cfg:, timeout:, open_timeout:)
            Faraday.new(url: base_url) do |f|
              f.options.timeout = timeout
              f.options.open_timeout = open_timeout
              f.headers['Accept'] = 'application/json'
              apply_auth_headers(faraday: f, instance_cfg: instance_cfg)
              f.adapter Faraday.default_adapter
            end
          end

          # Default auth: the bearer token. A provider with extra request
          # headers (OpenAI org/project, ...) overrides this to add them.
          def apply_auth_headers(faraday:, instance_cfg:)
            token = auth_token(instance_cfg: instance_cfg)
            faraday.headers['Authorization'] = "Bearer #{token}" if token
          end

          def finish_probe_safely(coordinator, request: nil)
            coordinator.finish_probe(request: request)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: "#{provider_family}.runner.discovery.finish_probe")
          end
        end
      end
    end
  end
end
