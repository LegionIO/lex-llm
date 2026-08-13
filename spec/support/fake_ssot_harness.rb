# frozen_string_literal: true

require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'

module SpecSupport
  # A distinct fake provider callable. Records inference calls and readiness
  # probes separately so the conformance examples can prove that safe readiness
  # performs no inference.
  class FakeSsotCallable
    attr_reader :inference_calls, :readiness_probes, :disconnects

    def initialize
      @inference_calls = 0
      @readiness_probes = 0
      @disconnects = 0
    end

    def disconnect
      @disconnects += 1
    end

    # Non-inference control-plane readiness (e.g. a model-list/status call).
    def control_plane_ready?
      @readiness_probes += 1
      true
    end

    def chat(messages:, model:, **rest)
      @inference_calls += 1
      { content: "fake chat #{model} #{messages.size} #{rest.size}" }
    end
  end

  # Phase 1 fake implementation of the shared SSOT v3 provider-harness interface
  # consumed by 'an SSOT v3 provider adapter'. See phase-1-lex-llm-additive.md
  # Task 12.
  class FakeSsotHarness
    def provider_family
      :vllm
    end

    def instance_configs
      [{ instance_id: 'h200', model: 'gemma4' }, { instance_id: 'helios1', model: 'gemma4' }].freeze
    end

    def instance_id(instance_config:)
      instance_config.fetch(:instance_id)
    end

    def build_callable(instance_config:)
      _ = instance_config
      FakeSsotCallable.new
    end

    def build_offering_drafts(instance_config:, callable:, tier: :local)
      _ = callable
      [offering_draft(instance_config.fetch(:model), tier)].freeze
    end

    def safe_readiness(instance_config:, callable:)
      _ = instance_config
      callable.control_plane_ready?
      Legion::Extensions::Llm::Inventory::ReadinessResult.new(ready: true, reason: 'control-plane model list ok')
    end

    def inference_call_count(callable:)
      callable.inference_calls
    end

    def normalize_dispatch_error(error:)
      routing = Legion::Extensions::Llm::Routing
      case error[:kind]
      when :instance_unavailable then routing::ProviderOutcome.new(kind: :instance_unavailable, reason: 'explicit service unavailable')
      when :overloaded then routing::ProviderOutcome.new(kind: :overloaded, reason: 'HTTP 503 overloaded')
      when :model_not_ready then routing::ProviderOutcome.new(kind: :model_not_ready, reason: 'HTTP 503 model loading')
      else routing::ProviderOutcome.new(kind: :provider_error, reason: 'unclassified provider error')
      end
    end

    def instance_unavailable_error
      { kind: :instance_unavailable, http_status: 503 }
    end

    def overloaded_error
      { kind: :overloaded, http_status: 503 }
    end

    def model_not_ready_error
      { kind: :model_not_ready, http_status: 503 }
    end

    private

    def offering_draft(model, tier)
      Legion::Extensions::Llm::Inventory::OfferingDraft.new(
        provider_native_key: model, model: model, tier: tier, operation_evidence: operation_evidence,
        context_evidence: unknown_value, max_output_evidence: unknown_value,
        embedding_dimensions_evidence: unknown_value, model_revision_evidence: unknown_value,
        tokenizer_evidence: unknown_value, publication_source: :provider_catalog
      )
    end

    def operation_evidence
      Legion::Extensions::Llm::Taxonomies::OPERATIONS.to_h do |op|
        status, source = op == :chat ? %i[supported provider_implementation] : %i[unknown absent]
        [op, Legion::Extensions::Llm::Inventory::OperationEvidence.new(operation: op, status: status, source: source)]
      end
    end

    def unknown_value
      Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
    end
  end
end
