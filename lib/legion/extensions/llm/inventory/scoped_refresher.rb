# frozen_string_literal: true

require 'legion/logging'
require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/snapshot'
require 'legion/extensions/llm/taxonomies'

module Legion
  module Extensions
    module Llm
      module Inventory
        # DEPRECATED (Phase 4 removal): the only Phase 1 file permitted to hold a
        # direct `Legion::LLM::Inventory` reverse reference. Old released provider
        # actors keep using ScopedRefresher#tick until their Phase 2 migration; a
        # migrated actor instead injects ScopedRefresher::LegacyCoordinatorAdapter
        # into Inventory::Publisher and never calls #tick. Neither old lane hashes
        # nor old health feed the new registry. Phase 4 deletes this file once
        # every provider and coordinator floor has migrated.
        #
        # Mix into a Legion::Extensions::Llm::*::Actors::DiscoveryRefresh class.
        # The host class must include Legion::Extensions::Helpers::Lex (auto-injects
        # log / settings / handle_exception / cache_*) and define:
        #   - #scope_key          — Hash like { provider: :vllm, instance: instance_id }
        #   - #compute_lanes_for_scope — Array<Hash> lane fact-sheets (no health, no
        #                               lane_weight — added by Inventory.write_lane).
        #                               Each lane MUST set :id via compose_id.
        #   - #credential_hash    — String identifying the auth credential for this scope
        #                           (used by the auth-failure cooldown circuit).
        module ScopedRefresher
          # Auth-failure cooldown TTL (5 minutes). Operator can fix the credential
          # and lanes auto-recover on the next tick after expiry.
          AUTH_COOLDOWN_TTL = 300

          # G22: 5-part lane id composed here and ONLY here. All gem writers MUST call
          # this helper; Inventory.write_lane rejects any lane with a missing or malformed :id.
          # Accepts a Hash (or keyword splat) with keys: tier, provider_family, instance_id, type, model.
          def self.compose_id(lane_fields)
            t  = lane_fields[:tier]
            pf = lane_fields[:provider_family]
            ii = lane_fields[:instance_id]
            ty = lane_fields[:type]
            mo = lane_fields[:model]
            "#{t}:#{pf}:#{ii}:#{ty}:#{mo}"
          end

          # G7 write-then-delete-orphans: write new lanes FIRST (eliminates zero-results
          # race window), then delete orphans from the previous scope snapshot.
          def tick(**)
            return if auth_cooldown_active?

            new_lanes = safe_compute
            log.info("[llm][scoped_refresher] action=tick provider=#{scope_key[:provider]} lanes_computed=#{new_lanes ? new_lanes.size : 0}")
            return unless new_lanes&.any?

            written = 0
            new_lanes.each do |lane_fact|
              written += 1 if Legion::LLM::Inventory.write_lane(lane: lane_fact)
            end
            log.info("[llm][scoped_refresher] action=tick_complete provider=#{scope_key[:provider]} lanes_computed=#{new_lanes.size} lanes_written=#{written}")

            orphans = (@prev_scope_keys || []) - new_lanes.map { it[:id] }
            orphans.each { |id| Legion::LLM::Inventory.delete_lane(id: id) }

            @prev_scope_keys = new_lanes.map { it[:id] }
          end

          private

          # Wraps compute_lanes_for_scope with auth-failure cooldown logic.
          # If a cooldown key is present from a previous auth failure, skips the
          # compute entirely (no real call burned). On a new auth failure, writes the
          # cooldown key with AUTH_COOLDOWN_TTL so subsequent ticks also skip.
          def safe_compute
            if auth_cooldown_active?
              log.warn("[llm][scoped_refresher] action=skip reason=auth_cooldown scope=#{scope_key}")
              return nil
            end
            compute_lanes_for_scope
          rescue NotImplementedError
            raise
          rescue StandardError => e
            if auth_failure?(error: e)
              Legion::Cache::Local.set(auth_cooldown_key, 1, ttl: AUTH_COOLDOWN_TTL)
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'inventory.scoped_refresher.auth_failure',
                                  scope: scope_key)
            else
              handle_exception(e, level: :warn, handled: true,
                                  operation: 'inventory.scoped_refresher.compute',
                                  scope: scope_key)
            end
            nil
          end

          def auth_cooldown_active?
            !Legion::Cache::Local.get(auth_cooldown_key).nil?
          rescue StandardError
            false
          end

          def auth_cooldown_key
            "llm_auth_failed:#{credential_hash}"
          end

          # Default auth-failure predicate. Matches HTTP 401/403 status codes and
          # common auth-error message patterns. Provider gems may override this if
          # their error shapes differ (e.g. Bedrock's AccessDeniedException).
          def auth_failure?(error:, **)
            return true if error.respond_to?(:status_code) && [401, 403].include?(error.status_code)
            return true if error.respond_to?(:http_status) && [401, 403].include?(error.http_status)

            error.message&.match?(/unauthorized|invalid[_ ]api[_ ]key|invalid[_ ]credentials|forbidden/i)
          end

          # One-way, post-commit projection of an already-committed new Snapshot
          # into the old Legion::LLM::Inventory coordinator, for the mixed-version
          # window only. It never rediscovers, selects, authorizes new state, or
          # feeds an old fact back into the new Registry. See section 13.3.
          class LegacyCoordinatorAdapter
            include Legion::Logging::Helper

            HEALTHY_COMPAT = { circuit_state: :closed, denied: false, available: true, adjustment: 0 }.freeze
            LEGACY_CAPABILITIES = {
              chat: :completion, stream_chat: :streaming, embed: :embedding, image: :image,
              transcribe: :audio_transcription, translate: :audio_transcription, speak: :audio_speech, moderate: :moderation
            }.freeze

            def initialize(provider_family:, legacy_instance_ids_by_instance: {})
              @provider_family = canonical_family(provider_family)
              @legacy_instance_ids = deep_freeze_legacy_ids(legacy_instance_ids_by_instance)
              @published_ids_by_instance = {}.freeze
              @mutex = Mutex.new
            end

            def sync_snapshot(snapshot:, instance_key:, mutation_reason:)
              validate_inputs!(snapshot, instance_key, mutation_reason)
              return :not_loaded unless legacy_inventory_available?

              project(snapshot, instance_key)
            end

            private

            def project(snapshot, instance_key)
              @mutex.synchronize { project_locked(snapshot, instance_key) }
              :applied
            rescue StandardError => e
              handle_exception(
                e, handled: true, level: :warn, operation: 'inventory.scoped_refresher.legacy_projection',
                   provider_family: @provider_family, instance_id: instance_key.instance_id,
                   source_generation: snapshot.generation
              )
              :failed
            end

            def project_locked(snapshot, instance_key)
              desired = desired_lanes(snapshot, instance_key)
              written = write_desired(desired)
              reconcile_deletions(instance_key, written)
              @published_ids_by_instance = @published_ids_by_instance.merge(
                instance_key.instance_id => written.to_a.freeze
              ).freeze
            end

            def desired_lanes(snapshot, instance_key)
              record = snapshot.instance(instance_key: instance_key)
              return {} if record.nil? || record.availability.state != :available

              build_desired(group_lanes(snapshot, instance_key), snapshot.generation)
            end

            def group_lanes(snapshot, instance_key)
              groups = {}
              snapshot.lanes_for(instance_key: instance_key).each do |lane|
                type = Taxonomies.lane_type_for(operation: lane.operation)
                key = [lane.tier, instance_key.provider_family, instance_key.instance_id, type, lane.model]
                group = (groups[key] ||= new_group(instance_key, lane, type))
                accumulate_group(group, lane)
              end
              groups
            end

            def new_group(instance_key, lane, type)
              {
                tier: lane.tier, provider_family: instance_key.provider_family, instance_id: instance_key.instance_id,
                type: type, model: lane.model, offering_ids: Set.new, capabilities: Set.new,
                context_values: Set.new, max_output_values: Set.new
              }
            end

            def accumulate_group(group, lane)
              group[:offering_ids] << lane.offering_id
              mapped = LEGACY_CAPABILITIES[lane.operation]
              group[:capabilities] << mapped if mapped
              lane.capability_evidence.each { |capability, evidence| group[:capabilities] << capability if evidence.supported? }
              group[:context_values] << lane.context_evidence.value if lane.context_evidence.known?
              group[:max_output_values] << lane.max_output_evidence.value if lane.max_output_evidence.known?
            end

            def build_desired(groups, generation)
              by_id = {}
              groups.each_value do |group|
                legacy_id = ScopedRefresher.compose_id(identity_fields(group))
                (by_id[legacy_id] ||= []) << group
              end

              by_id.each_with_object({}) do |(legacy_id, colliding), desired|
                if colliding.size > 1 || colliding.first[:offering_ids].size != 1
                  log.warn("[llm][inventory][legacy_adapter] action=fail_closed reason=ambiguous_group legacy_id=#{legacy_id}")
                  next
                end
                desired[legacy_id] = build_lane_hash(legacy_id, colliding.first, generation)
              end
            end

            def identity_fields(group)
              {
                tier: group[:tier], provider_family: group[:provider_family],
                instance_id: group[:instance_id], type: group[:type], model: group[:model]
              }.freeze
            end

            def build_lane_hash(legacy_id, group, generation)
              {
                id: legacy_id, tier: group[:tier], provider_family: group[:provider_family],
                provider_instance: group[:instance_id], instance_id: group[:instance_id], type: group[:type],
                model: group[:model], offering_id: group[:offering_ids].first,
                capabilities: group[:capabilities].to_a.sort, limits: build_limits(group),
                metadata: { ssot_v3_compatibility_projection: true, source_generation: generation }, enabled: true
              }
            end

            def build_limits(group)
              limits = {}
              limits[:context_window] = group[:context_values].first if group[:context_values].size == 1
              limits[:max_output_tokens] = group[:max_output_values].first if group[:max_output_values].size == 1
              limits
            end

            def write_desired(desired)
              written = Set.new
              desired.each do |legacy_id, lane_hash|
                result = ::Legion::LLM::Inventory.write_lane(lane: lane_hash, health: HEALTHY_COMPAT)
                written << legacy_id unless result.nil?
              end
              written
            end

            def reconcile_deletions(instance_key, written)
              tracked = @published_ids_by_instance.fetch(instance_key.instance_id, [])
              candidates = (tracked.to_a + read_current_old_ids(instance_key).to_a).uniq
              candidates.each do |old_id|
                next if written.include?(old_id)

                ::Legion::LLM::Inventory.delete_lane(id: old_id)
              end
            end

            def read_current_old_ids(instance_key)
              instance_ids_to_read(instance_key).each_with_object(Set.new) do |instance_id, ids|
                lanes = ::Legion::LLM::Inventory.lanes_for(provider: @provider_family, instance: instance_id)
                Array(lanes).each { |lane| ids << (lane.is_a?(::Hash) ? lane[:id] : lane) }
              end
            end

            def instance_ids_to_read(instance_key)
              ([instance_key.instance_id] + @legacy_instance_ids.fetch(instance_key.instance_id, [])).uniq
            end

            def validate_inputs!(snapshot, instance_key, mutation_reason)
              raise Errors::ValidationError, 'snapshot must be an Inventory::Snapshot' unless snapshot.is_a?(Snapshot)
              unless instance_key.is_a?(Identity::InstanceKey) && instance_key.provider_family == @provider_family
                raise Errors::ValidationError, 'instance_key must belong to the adapter provider family'
              end
              return if Taxonomies::MUTATION_REASONS.include?(mutation_reason)

              raise Errors::ValidationError, 'mutation_reason must be a Taxonomies::MUTATION_REASONS value'
            end

            def legacy_inventory_available?
              defined?(::Legion::LLM::Inventory) &&
                ::Legion::LLM::Inventory.respond_to?(:lanes_for) &&
                ::Legion::LLM::Inventory.respond_to?(:write_lane) &&
                ::Legion::LLM::Inventory.respond_to?(:delete_lane)
            end

            def canonical_family(value)
              text = Identity.normalize_text(value: value, field: :provider_family).downcase
              raise Errors::ValidationError, 'provider_family must be snake-case ASCII' unless text.match?(/\A[a-z][a-z0-9_]*\z/)

              text.to_sym
            end

            def deep_freeze_legacy_ids(mapping)
              raise Errors::ValidationError, 'legacy_instance_ids_by_instance must be a Hash' unless mapping.is_a?(::Hash)

              mapping.each_with_object({}) do |(key, values), frozen|
                raise Errors::ValidationError, 'legacy instance id keys must be Strings' unless key.is_a?(::String)
                raise Errors::ValidationError, 'legacy superseded ids must be a nonempty Array of Strings' unless values.is_a?(::Array) && !values.empty? && values.all?(::String)

                frozen[key.dup.freeze] = values.map { |value| value.dup.freeze }.freeze
              end.freeze
            end
          end
        end
      end
    end
  end
end
