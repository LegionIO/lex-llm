# frozen_string_literal: true

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
        # selection, scheduling, defaulting, or provider discovery. M7: the
        # legacy dual-sink seam (compatibility_adapter / old-coordinator
        # projection) is deleted — one representation, one routing authority;
        # the SSOT registry is the only inventory sink.
        class Publisher
          def initialize(provider_family:, registry: Registry)
            @provider_family = provider_family
            @registry = registry
          end

          # Every instance operation takes `instance_id:` — the operator's
          # CONFIG NAME (the identity the router keys by) — and an optional
          # `physical_id:` carrying the physical/derived id (host:port/ak) for
          # dedup and diagnostics only. See Identity::InstanceKey.
          def claim_instance(instance_id:, callable:, probe_request_handle:, physical_id: nil)
            key = instance_key(instance_id: instance_id, physical_id: physical_id)
            @registry.claim_instance(instance_key: key, callable: callable, probe_request_handle: probe_request_handle)
          end

          def readiness_probe_started(instance_id:, publisher_token:, physical_id: nil)
            @registry.readiness_probe_started(
              instance_key: instance_key(instance_id: instance_id, physical_id: physical_id), publisher_token: publisher_token
            )
          end

          def activate_instance_snapshot(instance_id:, publisher_token:, offerings:, sequence:, probe_token:, physical_id: nil) # rubocop:disable Metrics/ParameterLists
            @registry.activate_instance_snapshot(
              publisher_token: publisher_token, instance_key: instance_key(instance_id: instance_id, physical_id: physical_id),
              offerings: offerings, sequence: sequence, probe_token: probe_token
            )
          end

          def replace_instance_snapshot(instance_id:, publisher_token:, offerings:, sequence:, physical_id: nil)
            @registry.replace_instance_snapshot(
              publisher_token: publisher_token, instance_key: instance_key(instance_id: instance_id, physical_id: physical_id),
              offerings: offerings, sequence: sequence
            )
          end

          def readiness_succeeded(instance_id:, probe_token:, physical_id: nil)
            @registry.readiness_succeeded(instance_key: instance_key(instance_id: instance_id, physical_id: physical_id), probe_token: probe_token)
          end

          def readiness_failed(instance_id:, probe_token:, reason:, physical_id: nil)
            @registry.readiness_failed(instance_key: instance_key(instance_id: instance_id, physical_id: physical_id), probe_token: probe_token, reason: reason)
          end

          def remove_instance(instance_id:, publisher_token:, physical_id: nil)
            @registry.remove_instance(instance_key: instance_key(instance_id: instance_id, physical_id: physical_id), publisher_token: publisher_token)
          end

          def snapshot
            @registry.snapshot
          end

          private

          def instance_key(instance_id:, physical_id: nil)
            Identity::InstanceKey.new(provider_family: @provider_family, instance_id: instance_id, physical_id: physical_id)
          end
        end
      end
    end
  end
end
