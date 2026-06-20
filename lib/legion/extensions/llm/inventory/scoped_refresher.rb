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
        end
      end
    end
  end
end
