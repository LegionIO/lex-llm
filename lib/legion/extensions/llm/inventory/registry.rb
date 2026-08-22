# frozen_string_literal: true

require 'concurrent'
require 'securerandom'
require 'legion/logging'
require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/callable_handle'
require 'legion/extensions/llm/inventory/probe_token'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/snapshot'
require 'legion/extensions/llm/taxonomies'

module Legion
  module Extensions
    module Llm
      module Inventory
        # The only mutable SSOT owner: a module-level facade over one internal
        # synchronized Store. Production exposes no constructor. See
        # phase-1-lex-llm-additive.md section 12.
        module Registry
          # Private per-instance state. Never leaves registry.rb.
          ScopeState = ::Data.define(
            :instance_key, :publisher_token, :callable, :callable_handle, :probe_request_handle,
            :publication_status, :last_sequence, :availability, :lanes,
            :availability_revision, :unavailable_revision, :published_at
          )

          # Private issued-probe tracking. Never leaves registry.rb.
          IssuedProbeState = ::Data.define(:probe_token, :consumed)

          # The synchronized internal store. All validation-against-current plus
          # the root swap happen under @mutation_mutex; snapshot reads are
          # lock-free. It never calls a provider callable, disconnect, probe
          # enqueue handle, logger callback, or transport while holding the
          # mutex; those side effects run after the swap. See section 12.2.
          class Store
            include Legion::Logging::Helper

            def initialize
              @scopes = Concurrent::Map.new
              @issued_probe_tokens = Concurrent::Map.new
              @generation = 0
              @mutation_mutex = Mutex.new
              @snapshot_ref = Concurrent::AtomicReference.new(build_snapshot_locked)
            end

            def snapshot
              @snapshot_ref.get
            end

            def claim_instance(instance_key:, callable:, probe_request_handle:)
              validate_instance_key!(instance_key)
              raise Errors::ValidationError, 'callable must not be nil' if callable.nil?
              raise Errors::ValidationError, 'probe_request_handle must not be nil' if probe_request_handle.nil?

              handle = CallableHandle.new(handle_id: "call:v1:#{SecureRandom.uuid}", callable: callable)
              token = PublisherToken.issue(instance_key: instance_key)
              old_handle = install_claim(instance_key, callable, handle, probe_request_handle, token)
              old_handle&.retire
              token
            end

            def readiness_probe_started(instance_key:, publisher_token:)
              validate_instance_key!(instance_key)
              @mutation_mutex.synchronize do
                scope = @scopes[instance_key]
                classification = classify_publisher(scope, publisher_token, instance_key)
                raise Errors::FencedPublisherError, 'superseded or invalid publisher token' unless classification == :current

                issue_probe_token(scope)
              end
            end

            def activate_instance_snapshot(publisher_token:, instance_key:, offerings:, sequence:, probe_token:)
              validate_instance_key!(instance_key)
              drafts = ensure_drafts!(offerings)
              prepared = prepare_records(instance_key, drafts)
              @mutation_mutex.synchronize do
                scope = @scopes[instance_key]
                guard = guard_current(scope, publisher_token, instance_key)
                return guard if guard
                raise Errors::InvalidTransitionError, 'activate requires an initializing claim' unless scope.publication_status.state == :initializing
                return stale_mutation(scope, instance_key) unless prepared_matches?(prepared, scope)

                consume_probe_token!(probe_token, scope, instance_key)
                validate_sequence!(sequence, scope.last_sequence)
                apply_activation(scope, instance_key, prepared, sequence, probe_token)
              end
            end

            def replace_instance_snapshot(publisher_token:, instance_key:, offerings:, sequence:)
              validate_instance_key!(instance_key)
              drafts = ensure_drafts!(offerings)
              prepared = prepare_records(instance_key, drafts)
              @mutation_mutex.synchronize do
                scope = @scopes[instance_key]
                guard = guard_current(scope, publisher_token, instance_key)
                return guard if guard
                raise Errors::InvalidTransitionError, 'replace requires an activated instance' unless activated?(scope)
                return stale_mutation(scope, instance_key) unless prepared_matches?(prepared, scope)

                validate_sequence!(sequence, scope.last_sequence)
                apply_replacement(scope, instance_key, prepared, sequence)
              end
            end

            def readiness_succeeded(instance_key:, probe_token:)
              validate_instance_key!(instance_key)
              @mutation_mutex.synchronize do
                scope = @scopes[instance_key]
                return absent_stale(instance_key) if scope.nil?

                probe_guard = guard_probe_publisher(scope, probe_token, instance_key)
                return probe_guard if probe_guard
                raise Errors::InvalidTransitionError, 'readiness_succeeded before activation' if scope.publication_status.state == :initializing

                consume_probe_token!(probe_token, scope, instance_key)
                apply_readiness_success(scope, instance_key, probe_token)
              end
            end

            def readiness_failed(instance_key:, probe_token:, reason:)
              validate_instance_key!(instance_key)
              @mutation_mutex.synchronize do
                scope = @scopes[instance_key]
                return absent_stale(instance_key) if scope.nil?

                probe_guard = guard_probe_publisher(scope, probe_token, instance_key)
                return probe_guard if probe_guard

                consume_probe_token!(probe_token, scope, instance_key)
                apply_readiness_failure(scope, instance_key, probe_token, reason)
              end
            end

            def dispatch_instance_unavailable(instance_key:, publisher_token_id:, reason:)
              validate_instance_key!(instance_key)
              side_effect = nil
              result =
                @mutation_mutex.synchronize do
                  scope = @scopes[instance_key]
                  return absent_stale(instance_key) if scope.nil?
                  return stale_mutation(scope, instance_key) unless scope.publisher_token.publisher_token_id == publisher_token_id
                  raise Errors::InvalidTransitionError, 'dispatch_instance_unavailable requires an activated instance' unless activated?(scope)

                  mutation, side_effect = apply_dispatch_unavailable(scope, instance_key, reason)
                  mutation
                end
              enqueue_probe(*side_effect) if side_effect
              result
            end

            def remove_instance(instance_key:, publisher_token:)
              validate_instance_key!(instance_key)
              old_handle = nil
              result =
                @mutation_mutex.synchronize do
                  scope = @scopes[instance_key]
                  return absent_removed(instance_key) if scope.nil?

                  guard = guard_current(scope, publisher_token, instance_key)
                  return guard if guard

                  old_handle = scope.callable_handle
                  @scopes.delete(instance_key)
                  bump_and_snapshot!
                  MutationResult.new(applied: true, reason: :removed, generation: @generation, instance_key: instance_key)
                end
              old_handle&.retire
              result
            end

            def acquire(callable_handle:)
              raise Errors::UnknownCallableError, 'acquire requires a CallableHandle' unless callable_handle.is_a?(CallableHandle)

              callable_handle.acquire
            end

            def retire_all_handles
              @scopes.each_value { |scope| scope.callable_handle.retire }
            end

            private

            # --- Claim -------------------------------------------------------

            def install_claim(instance_key, callable, handle, probe_request_handle, token)
              @mutation_mutex.synchronize do
                prior = @scopes[instance_key]
                raise Errors::ValidationError, 'a new claim must provide a distinct callable object' if prior && prior.callable.equal?(callable)

                status = PublicationStatus.new(
                  instance_key: instance_key, state: :initializing,
                  publisher_token_id: token.publisher_token_id, published_sequence: nil
                )
                @scopes[instance_key] = ScopeState.new(
                  instance_key: instance_key, publisher_token: token, callable: callable, callable_handle: handle,
                  probe_request_handle: probe_request_handle, publication_status: status,
                  last_sequence: -1, availability: nil, lanes: {},
                  availability_revision: prior&.availability_revision || 0,
                  unavailable_revision: prior&.unavailable_revision, published_at: nil
                )
                bump_and_snapshot!
                prior&.callable_handle
              end
            end

            # --- Activation --------------------------------------------------

            def apply_activation(scope, instance_key, prepared, sequence, probe_token)
              now = Time.now
              new_rev = scope.availability_revision + 1
              availability = AvailabilityFact.new(
                state: :available, availability_revision: new_rev, source: :startup_readiness,
                reason: 'startup readiness succeeded', observed_at: now,
                last_probe_started_at: probe_token.started_at, last_probe_completed_at: now, last_probe_outcome: :success
              )
              status = complete_status(scope, sequence, probe_token, now, :success)
              new_scope = scope.with(
                publication_status: status, last_sequence: sequence, availability: availability,
                lanes: prepared[1], availability_revision: new_rev,
                unavailable_revision: nil, published_at: now
              )
              @scopes[instance_key] = new_scope
              bump_and_snapshot!
              applied(:activated, new_scope)
            end

            def complete_status(scope, sequence, probe_token, now, outcome)
              scope.publication_status.with(
                state: :complete, published_sequence: sequence, last_probe_started_at: probe_token.started_at,
                last_probe_completed_at: now, last_probe_outcome: outcome
              )
            end

            # --- Replacement -------------------------------------------------

            def apply_replacement(scope, instance_key, prepared, sequence)
              status = scope.publication_status.with(published_sequence: sequence)
              new_scope = scope.with(lanes: prepared[1], last_sequence: sequence, publication_status: status)
              @scopes[instance_key] = new_scope
              bump_and_snapshot!
              applied(:snapshot_replaced, new_scope)
            end

            # --- Readiness success -------------------------------------------

            def apply_readiness_success(scope, instance_key, probe_token)
              if scope.availability.state == :available
                observe_available_success(scope, instance_key, probe_token)
              elsif probe_token.started_availability_revision >= scope.unavailable_revision
                recover_instance(scope, instance_key, probe_token)
              else
                MutationResult.new(
                  applied: false, reason: :stale_probe, generation: @generation, instance_key: instance_key,
                  publication_status: scope.publication_status, instance_record: instance_record_for(scope)
                )
              end
            end

            def observe_available_success(scope, instance_key, probe_token)
              now = Time.now
              availability = scope.availability.with(
                source: :readiness, last_probe_started_at: probe_token.started_at,
                last_probe_completed_at: now, last_probe_outcome: :success
              )
              status = scope.publication_status.with(
                last_probe_started_at: probe_token.started_at, last_probe_completed_at: now, last_probe_outcome: :success
              )
              new_scope = scope.with(availability: availability, publication_status: status)
              @scopes[instance_key] = new_scope
              bump_and_snapshot!
              applied(:readiness_observed, new_scope)
            end

            def recover_instance(scope, instance_key, probe_token)
              now = Time.now
              new_rev = scope.availability_revision + 1
              availability = AvailabilityFact.new(
                state: :available, availability_revision: new_rev, source: :readiness,
                reason: 'readiness recovered exact instance', observed_at: now,
                last_probe_started_at: probe_token.started_at, last_probe_completed_at: now, last_probe_outcome: :success
              )
              status = scope.publication_status.with(
                last_probe_started_at: probe_token.started_at, last_probe_completed_at: now, last_probe_outcome: :success
              )
              new_scope = scope.with(
                availability: availability, availability_revision: new_rev, unavailable_revision: nil, publication_status: status
              )
              @scopes[instance_key] = new_scope
              bump_and_snapshot!
              applied(:instance_recovered, new_scope)
            end

            # --- Readiness failure -------------------------------------------

            def apply_readiness_failure(scope, instance_key, probe_token, reason)
              now = Time.now
              if scope.publication_status.state == :initializing
                status = scope.publication_status.with(
                  last_probe_started_at: probe_token.started_at, last_probe_completed_at: now,
                  last_probe_outcome: :failure, last_error: reason
                )
                new_scope = scope.with(publication_status: status)
                @scopes[instance_key] = new_scope
                bump_and_snapshot!
                return MutationResult.new(
                  applied: true, reason: :initial_readiness_failed, generation: @generation,
                  instance_key: instance_key, publication_status: status
                )
              end
              mark_unavailable_from_readiness(scope, instance_key, probe_token, reason, now)
            end

            def mark_unavailable_from_readiness(scope, instance_key, probe_token, reason, now)
              new_rev = scope.availability_revision + 1
              availability = AvailabilityFact.new(
                state: :unavailable, availability_revision: new_rev, source: :readiness, reason: reason, observed_at: now,
                last_probe_started_at: probe_token.started_at, last_probe_completed_at: now,
                last_probe_outcome: :failure, unavailable_revision: new_rev
              )
              status = scope.publication_status.with(
                last_probe_started_at: probe_token.started_at, last_probe_completed_at: now,
                last_probe_outcome: :failure, last_error: reason
              )
              new_scope = scope.with(
                availability: availability, availability_revision: new_rev, unavailable_revision: new_rev, publication_status: status
              )
              @scopes[instance_key] = new_scope
              bump_and_snapshot!
              applied(:instance_unavailable, new_scope)
            end

            # --- Dispatch-reported unavailable -------------------------------

            def apply_dispatch_unavailable(scope, instance_key, reason)
              now = Time.now
              new_rev = scope.availability_revision + 1
              availability = AvailabilityFact.new(
                state: :unavailable, availability_revision: new_rev, source: :dispatch, reason: reason,
                observed_at: now, unavailable_revision: new_rev
              )
              new_scope = scope.with(availability: availability, availability_revision: new_rev, unavailable_revision: new_rev)
              @scopes[instance_key] = new_scope
              bump_and_snapshot!
              [applied(:instance_unavailable, new_scope),
               [scope.probe_request_handle, instance_key, scope.publisher_token.publisher_token_id, new_rev, reason]]
            end

            def enqueue_probe(handle, instance_key, token_id, unavailable_revision, reason)
              handle.enqueue_probe_request(
                instance_key: instance_key, publisher_token_id: token_id,
                unavailable_revision: unavailable_revision, reason: reason
              )
            rescue StandardError => e
              handle_exception(
                e, handled: true, level: :warn, operation: 'llm.inventory.registry.enqueue_probe',
                   provider_family: instance_key.provider_family, instance_id: instance_key.instance_id
              )
            end

            # --- Probe token single-use --------------------------------------

            def issue_probe_token(scope)
              token = ProbeToken.issue(
                instance_key: scope.instance_key, publisher_token_id: scope.publisher_token.publisher_token_id,
                started_availability_revision: scope.availability_revision, started_at: Time.now
              )
              @issued_probe_tokens[token.token_id] = IssuedProbeState.new(probe_token: token, consumed: false)
              status = scope.publication_status.with(last_probe_started_at: token.started_at)
              @scopes[scope.instance_key] = scope.with(publication_status: status)
              bump_and_snapshot!
              token
            end

            def consume_probe_token!(probe_token, scope, instance_key)
              validate_probe_token_shape!(probe_token, instance_key)
              issued = @issued_probe_tokens[probe_token.token_id]
              raise Errors::InvalidProbeError, 'unknown probe token' if issued.nil?
              raise Errors::InvalidProbeError, 'probe token already consumed' if issued.consumed
              raise Errors::InvalidProbeError, 'probe token does not belong to the current publisher' unless probe_token.publisher_token_id == scope.publisher_token.publisher_token_id

              @issued_probe_tokens[probe_token.token_id] = issued.with(consumed: true)
            end

            def validate_probe_token_shape!(probe_token, instance_key)
              return if probe_token.is_a?(ProbeToken) && probe_token.instance_key == instance_key

              raise Errors::InvalidProbeError, 'probe token is malformed or for another instance'
            end

            # --- Fencing -----------------------------------------------------

            def classify_publisher(scope, token, instance_key)
              return :fenced unless token.is_a?(PublisherToken) && token.instance_key == instance_key
              return :stale if scope.nil?

              if scope.publisher_token.publisher_token_id == token.publisher_token_id
                scope.publisher_token.authenticates?(token) ? :current : :fenced
              else
                :stale
              end
            end

            # Returns a MutationResult when the publisher is not current, nil when
            # it is current. Raises FencedPublisherError for a forged/malformed
            # token.
            def guard_current(scope, token, instance_key)
              case classify_publisher(scope, token, instance_key)
              when :fenced then raise Errors::FencedPublisherError, 'invalid or forged publisher token'
              when :stale then stale_mutation(scope, instance_key)
              end
            end

            def guard_probe_publisher(scope, probe_token, instance_key)
              validate_probe_token_shape!(probe_token, instance_key)
              return nil if probe_token.publisher_token_id == scope.publisher_token.publisher_token_id

              stale_mutation(scope, instance_key)
            end

            # --- Snapshot construction ---------------------------------------

            def bump_and_snapshot!
              @generation += 1
              @snapshot_ref.set(build_snapshot_locked)
            end

            def build_snapshot_locked
              instances = {}
              lanes = {}
              statuses = {}
              @scopes.each_pair do |key, scope|
                statuses[key] = scope.publication_status
                next if scope.availability.nil?

                instances[key] = instance_record_for(scope)
                lanes.merge!(scope.lanes)
              end
              Snapshot.new(
                generation: @generation, instances_by_key: instances,
                lanes_by_id: lanes, publication_status_by_key: statuses
              )
            end

            def instance_record_for(scope)
              InstanceRecord.new(
                instance_key: scope.instance_key, callable_handle: scope.callable_handle, availability: scope.availability,
                lanes_by_id: scope.lanes, publisher_id: scope.publisher_token.publisher_id,
                publisher_token_id: scope.publisher_token.publisher_token_id, published_sequence: scope.last_sequence,
                published_at: scope.published_at
              )
            end

            # --- Record derivation (pure; no I/O or application callbacks) ----

            def prepare_records(instance_key, drafts)
              scope = @scopes[instance_key]
              return nil if scope.nil?

              [scope.callable_handle, build_records(instance_key, scope.callable_handle, drafts)]
            end

            def prepared_matches?(prepared, scope)
              !prepared.nil? && prepared[0].equal?(scope.callable_handle)
            end

            # The stored inventory is lanes ONLY, keyed by the 5 tuple
            # tier:provider_family:instance_id:type:model. The 4th part is the
            # COARSE type, not the fine operation: the operations a draft
            # supports collapse to one lane per distinct type (chat +
            # stream_chat + count_tokens are ONE inference lane — the v0.15.2
            # model, where the operation is a request property matched against
            # the lane type, not a lane identity part). The LaneRecord's
            # operation member is the first supported operation of the lane's
            # type in canonical order — the representative, not the identity.
            # A duplicate (operation, model) published under a conflicting
            # tier, or a second draft claiming an already-published 5 tuple,
            # raises — never a silent merge (D1).
            def build_records(instance_key, handle, drafts)
              lanes = {}
              native_keys = {}
              op_model_tiers = {}
              drafts.each do |draft|
                raise Errors::ValidationError, 'duplicate provider_native_key' if native_keys.key?(draft.provider_native_key)

                native_keys[draft.provider_native_key] = true
                draft.operation_evidence.each_value do |evidence|
                  next unless evidence.supported?

                  op_model = [evidence.operation, draft.model]
                  raise Errors::ValidationError, 'duplicate (operation, model) published under a conflicting tier' if op_model_tiers.key?(op_model) && op_model_tiers[op_model] != draft.tier

                  op_model_tiers[op_model] = draft.tier
                end

                # One lane per distinct type the draft supports.
                draft.operation_evidence.each_value
                     .select(&:supported?)
                     .group_by { |evidence| Taxonomies.lane_type_for(operation: evidence.operation) }
                     .each do |type, evidences|
                  representative = evidences.min_by { |evidence| Taxonomies::OPERATIONS.index(evidence.operation) }
                  lane_id = Identity.compose_lane_id(
                    tier: draft.tier, provider_family: instance_key.provider_family,
                    instance_id: instance_key.instance_id, type: type, model: draft.model
                  )
                  raise Errors::ValidationError, 'duplicate lane_id' if lanes.key?(lane_id)

                  lanes[lane_id] = build_lane_record(instance_key, handle, draft, type, representative.operation)
                end
              end
              lanes.freeze
            end

            def build_lane_record(instance_key, handle, draft, type, operation)
              LaneRecord.new(
                lane_id: Identity.compose_lane_id(
                  tier: draft.tier, provider_family: instance_key.provider_family,
                  instance_id: instance_key.instance_id, type: type, model: draft.model
                ),
                instance_key: instance_key,
                provider_family: instance_key.provider_family, instance_id: instance_key.instance_id,
                model: draft.model, tier: draft.tier, operation: operation,
                capability_evidence: draft.capability_evidence, context_evidence: draft.context_evidence,
                max_output_evidence: draft.max_output_evidence,
                embedding_dimensions_evidence: draft.embedding_dimensions_evidence,
                model_revision_evidence: draft.model_revision_evidence, tokenizer_evidence: draft.tokenizer_evidence,
                quota_domain: draft.quota_domains[operation], metadata: draft.metadata,
                callable_handle: handle, publication_source: draft.publication_source,
                weight_inputs: draft.weight_inputs, base_weight: draft.base_weight
              )
            end

            # --- Small validators and result builders ------------------------

            def ensure_drafts!(offerings)
              raise Errors::ValidationError, 'offerings must be an Array of OfferingDraft' unless offerings.is_a?(::Array)
              raise Errors::ValidationError, 'offerings must contain only OfferingDraft values' unless offerings.all?(OfferingDraft)

              offerings
            end

            def validate_instance_key!(instance_key)
              raise Errors::ValidationError, 'instance_key must be an InstanceKey' unless instance_key.is_a?(Identity::InstanceKey)
            end

            def validate_sequence!(sequence, last_sequence)
              return if sequence.is_a?(::Integer) && !sequence.negative? && sequence > last_sequence

              raise Errors::StaleSequenceError, 'sequence must be a nonnegative Integer greater than the last accepted sequence'
            end

            def activated?(scope)
              !scope.availability.nil? && scope.publication_status.state == :complete
            end

            def applied(reason, scope)
              MutationResult.new(
                applied: true, reason: reason, generation: @generation, instance_key: scope.instance_key,
                publication_status: scope.publication_status, instance_record: instance_record_for(scope)
              )
            end

            def stale_mutation(scope, instance_key)
              MutationResult.new(
                applied: false, reason: :stale_publisher, generation: @generation, instance_key: instance_key,
                publication_status: scope&.publication_status,
                instance_record: scope&.availability ? instance_record_for(scope) : nil
              )
            end

            def absent_stale(instance_key)
              MutationResult.new(applied: false, reason: :stale_publisher, generation: @generation, instance_key: instance_key)
            end

            def absent_removed(instance_key)
              MutationResult.new(applied: false, reason: :already_removed, generation: @generation, instance_key: instance_key)
            end
          end

          class << self
            def claim_instance(...)
              store.claim_instance(...)
            end

            def readiness_probe_started(...)
              store.readiness_probe_started(...)
            end

            def activate_instance_snapshot(...)
              store.activate_instance_snapshot(...)
            end

            def replace_instance_snapshot(...)
              store.replace_instance_snapshot(...)
            end

            def readiness_succeeded(...)
              store.readiness_succeeded(...)
            end

            def readiness_failed(...)
              store.readiness_failed(...)
            end

            def dispatch_instance_unavailable(...)
              store.dispatch_instance_unavailable(...)
            end

            def remove_instance(...)
              store.remove_instance(...)
            end

            def snapshot
              store.snapshot
            end

            def acquire(...)
              store.acquire(...)
            end

            # Test-only: replace the store with a fresh generation-zero store and
            # retire prior handles outside its mutation mutex.
            def reset!
              raise Errors::InvalidTransitionError, 'Registry.reset! is only available under RSpec' unless defined?(::RSpec)

              previous = @store
              @store = Store.new
              previous&.retire_all_handles
              @store
            end

            private

            def store
              @store ||= Store.new
            end
          end
        end
      end
    end
  end
end
