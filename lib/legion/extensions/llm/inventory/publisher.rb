# frozen_string_literal: true

require 'legion/logging'
require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/registry'

module Legion
  module Extensions
    module Llm
      module Inventory
        # Provider-facing direct wrapper over the local Registry. It constructs
        # and validates the exact InstanceKey from its fixed provider family and
        # delegates to the registry with the exact kwargs. It does no retries,
        # selection, scheduling, defaulting, provider discovery, or exception
        # swallowing beyond the explicitly injected, best-effort post-commit
        # old-coordinator projection. See phase-1-lex-llm-additive.md section 13.1.
        class Publisher
          include Legion::Logging::Helper

          def initialize(provider_family:, registry: Registry, compatibility_adapter: nil)
            @provider_family = provider_family
            @registry = registry
            @compatibility_adapter = compatibility_adapter
          end

          # Every instance operation takes `instance_id:` — the operator's
          # CONFIG NAME (the identity the router keys by) — and an optional
          # `physical_id:` carrying the physical/derived id (host:port/ak) for
          # dedup and diagnostics only. See Identity::InstanceKey.
          def claim_instance(instance_id:, callable:, probe_request_handle:, physical_id: nil)
            key = instance_key(instance_id: instance_id, physical_id: physical_id)
            token = @registry.claim_instance(instance_key: key, callable: callable, probe_request_handle: probe_request_handle)
            sync_compatibility(key, :claimed)
            token
          end

          def readiness_probe_started(instance_id:, publisher_token:, physical_id: nil)
            @registry.readiness_probe_started(
              instance_key: instance_key(instance_id: instance_id, physical_id: physical_id), publisher_token: publisher_token
            )
          end

          def activate_instance_snapshot(instance_id:, publisher_token:, offerings:, sequence:, probe_token:, physical_id: nil) # rubocop:disable Metrics/ParameterLists
            key = instance_key(instance_id: instance_id, physical_id: physical_id)
            result = @registry.activate_instance_snapshot(
              publisher_token: publisher_token, instance_key: key, offerings: offerings,
              sequence: sequence, probe_token: probe_token
            )
            sync_applied(key, result)
          end

          def replace_instance_snapshot(instance_id:, publisher_token:, offerings:, sequence:, physical_id: nil)
            key = instance_key(instance_id: instance_id, physical_id: physical_id)
            result = @registry.replace_instance_snapshot(
              publisher_token: publisher_token, instance_key: key, offerings: offerings, sequence: sequence
            )
            sync_applied(key, result)
          end

          def readiness_succeeded(instance_id:, probe_token:, physical_id: nil)
            key = instance_key(instance_id: instance_id, physical_id: physical_id)
            sync_applied(key, @registry.readiness_succeeded(instance_key: key, probe_token: probe_token))
          end

          def readiness_failed(instance_id:, probe_token:, reason:, physical_id: nil)
            key = instance_key(instance_id: instance_id, physical_id: physical_id)
            sync_applied(key, @registry.readiness_failed(instance_key: key, probe_token: probe_token, reason: reason))
          end

          def remove_instance(instance_id:, publisher_token:, physical_id: nil)
            key = instance_key(instance_id: instance_id, physical_id: physical_id)
            sync_applied(key, @registry.remove_instance(instance_key: key, publisher_token: publisher_token))
          end

          def snapshot
            @registry.snapshot
          end

          private

          def instance_key(instance_id:, physical_id: nil)
            Identity::InstanceKey.new(provider_family: @provider_family, instance_id: instance_id, physical_id: physical_id)
          end

          def sync_applied(instance_key, result)
            sync_compatibility(instance_key, result.reason) if result.applied
            result
          end

          # Best-effort, post-commit projection into the old coordinator. It never
          # changes the local return and can never roll back or authorize the SSOT.
          def sync_compatibility(instance_key, mutation_reason)
            return if @compatibility_adapter.nil?

            outcome = @compatibility_adapter.sync_snapshot(
              snapshot: @registry.snapshot, instance_key: instance_key, mutation_reason: mutation_reason
            )
            return unless outcome == :failed

            log.warn(
              '[llm][inventory][publisher] action=compatibility_sync result=failed ' \
              "provider_family=#{instance_key.provider_family} instance=#{instance_key.instance_id} reason=#{mutation_reason}"
            )
          rescue StandardError => e
            handle_exception(
              e, handled: true, level: :warn, operation: 'llm.inventory.publisher.compatibility_sync',
                 provider_family: instance_key.provider_family, instance_id: instance_key.instance_id,
                 mutation_reason: mutation_reason
            )
          end
        end
      end
    end
  end
end
