# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Inventory
        # Mix into a Legion::Extensions::Llm::*::Actors::DiscoveryRefresh class.
        # The host class must include Legion::Extensions::Helpers::Lex (auto-injects
        # log / settings / handle_exception / cache_*) and define:
        #   - #scope_key          — Hash like { provider: :vllm, instance: instance_id }
        #   - #compute_lanes_for_scope — Array<Hash> lane fact-sheets (no health, no
        #                               lane_weight — added by Inventory.write_lane).
        #                               Each lane MUST set :id via compose_id.
        #   - #credential_hash    — String identifying the auth credential for this scope
        #                           (used by the cooldown circuit introduced in P2).
        module ScopedRefresher
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
            new_lanes = safe_compute
            return if new_lanes.nil?

            ttl = self.class.every_seconds * 3

            new_lanes.each do |lane_fact|
              Legion::LLM::Inventory.write_lane(lane: lane_fact, ttl: ttl)
            end

            orphans = (@prev_scope_keys || []) - new_lanes.map { it[:id] }
            orphans.each { |id| Legion::LLM::Inventory.delete_lane(id: id) }

            @prev_scope_keys = new_lanes.map { it[:id] }
          end

          private

          def safe_compute
            compute_lanes_for_scope
          rescue NotImplementedError
            raise
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true,
                                operation: 'inventory.scoped_refresher.compute',
                                scope: scope_key)
            nil
          end
        end
      end
    end
  end
end
