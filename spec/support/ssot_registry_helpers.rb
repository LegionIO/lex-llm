# frozen_string_literal: true

require 'legion/extensions/llm/inventory/registry'
require 'legion/extensions/llm/inventory/probe_coordinator'

# Shared builders for the SSOT v3 registry specs. Provides fake callables,
# instance keys, offering drafts, and a full claim -> probe -> activate helper so
# each registry spec exercises the public API rather than internal state.
module SsotRegistryHelpers
  module_function

  def registry
    Legion::Extensions::Llm::Inventory::Registry
  end

  def instance_key(family: 'vllm', instance: 'h200')
    Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(provider_family: family, instance_id: instance)
  end

  def fake_callable
    Class.new do
      attr_reader :disconnect_count

      def initialize
        @disconnect_count = 0
      end

      def disconnect
        @disconnect_count += 1
      end

      def chat(**)
        { ok: true }
      end
    end.new
  end

  def probe_coordinator(key, enqueue: ->(**) { true })
    Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(instance_key: key, enqueue: enqueue)
  end

  def unknown_value
    Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
  end

  def operation_evidence(supported: %i[chat])
    Legion::Extensions::Llm::Taxonomies::OPERATIONS.to_h do |op|
      status, source = supported.include?(op) ? %i[supported provider_implementation] : %i[unknown absent]
      [op, Legion::Extensions::Llm::Inventory::OperationEvidence.new(operation: op, status: status, source: source)]
    end
  end

  def drafts(model: 'gemma4', native: 'gemma4', supported: %i[chat], tier: :local, **weight_pair)
    [
      Legion::Extensions::Llm::Inventory::OfferingDraft.new(
        provider_native_key: native, model: model, tier: tier,
        operation_evidence: operation_evidence(supported: supported),
        context_evidence: unknown_value, max_output_evidence: unknown_value,
        embedding_dimensions_evidence: unknown_value, model_revision_evidence: unknown_value,
        tokenizer_evidence: unknown_value, publication_source: :provider_catalog,
        **weight_pair
      )
    ]
  end

  # Full claim -> probe -> activation lifecycle; returns the publisher token.
  # Extra keyword args (model:, native:, supported:, tier:) are forwarded to #drafts.
  def claim_and_activate(key:, callable:, coordinator:, sequence: 0, **draft_opts)
    token = registry.claim_instance(instance_key: key, callable: callable, probe_request_handle: coordinator)
    probe = registry.readiness_probe_started(instance_key: key, publisher_token: token)
    registry.activate_instance_snapshot(
      publisher_token: token, instance_key: key, offerings: drafts(**draft_opts), sequence: sequence, probe_token: probe
    )
    token
  end
end
