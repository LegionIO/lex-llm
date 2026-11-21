# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/fleet/worker_execution'
require 'legion/extensions/llm/fleet/provider_responder'
require 'support/ssot_registry_helpers'

RSpec.describe Legion::Extensions::Llm::Fleet::WorkerExecution do
  include SsotRegistryHelpers

  def key = instance_key(family: 'wire_probe', instance: 'primary')
  let(:provider) do
    Class.new(Legion::Extensions::Llm::Provider) do
      include Legion::Extensions::Llm::Provider::OpenAICompatible

      def self.slug = 'wire_probe'
      def api_base = 'https://provider.example'
    end.new(Legion::Extensions::Llm.config)
  end
  let(:messages) { [Legion::Extensions::Llm::Canonical::Message.build(role: :user, content: 'Check the status')] }
  let(:controls) do
    {
      tools: { lookup: tool },
      thinking: Legion::Extensions::Llm::Canonical::Thinking::Config.build(effort: 'high'),
      params: Legion::Extensions::Llm::Canonical::Params.build(temperature: 0.25, max_tokens: 512,
                                                               top_p: 0.8, stop_sequences: ['END'], seed: 7),
      headers: { 'X-Request-Probe' => 'preserved' }, tool_prefs: { choice: 'lookup' },
      schema: { name: 'status', schema: { type: 'object', properties: { status: { type: 'string' } } } }
    }
  end
  let(:captured) { [] }
  let(:stubs) do
    Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post('/v1/chat/completions') do |env|
        captured << { payload: Legion::JSON.load(env.body), header: env.request_headers['X-Request-Probe'] }
        body = { model: 'deployment', choices: [{ message: { role: 'assistant', content: 'ready' }, finish_reason: 'stop' }] }
        [200, { 'content-type' => 'application/json' }, Legion::JSON.dump(body)]
      end
    end
  end

  def tool
    Legion::Extensions::Llm::Canonical::ToolDefinition.build(
      name: 'lookup', description: 'Find a status',
      parameters: { type: 'object', properties: { query: { type: 'string' } }, required: ['query'] }
    )
  end

  around do |example|
    original = Legion::Settings[:extensions]
    Legion::Settings.loader.settings[:extensions] = Legion::Extensions::Llm::Utils.deep_merge(
      original || {}, { llm: { fleet: { responder: { require_auth: false, require_policy: false, require_idempotency: false } } } }
    )
    example.run
  ensure
    Legion::Settings.loader.settings[:extensions] = original
    Legion::Extensions::Llm::Inventory::Registry.reset!
  end

  before do
    Legion::Extensions::Llm::Inventory::Registry.reset!
    claim_and_activate(key: key, callable: provider, coordinator: probe_coordinator(key),
                       model: 'deployment', supported: %i[chat stream_chat])
    provider.connection.connection.builder.adapter :test, stubs
  end

  %i[chat stream_chat].each do |operation|
    %i[tools thinking params].each do |control|
      it "preserves serialized #{control} through the real #{operation} provider funnel" do
        selected = controls.slice(control)
        provider.public_send(operation, messages, model: 'deployment', **selected)
        wire = wire_envelope(operation: operation, controls: selected)
        response = described_class.call(envelope: wire, registry: registry)

        expect(response.text).to eq('ready')
        expect(captured.size).to eq(2)
        expect(captured.last).to eq(captured.first)
        expect(handle_reference_count).to eq(0)
      end
    end

    it "preserves combined controls and transport fields through #{operation}" do
      provider.public_send(operation, messages, model: 'deployment', **controls)
      wire = wire_envelope(operation: operation, controls: controls)
      original = Legion::JSON.dump(wire)
      described_class.call(envelope: wire, registry: registry)

      expect(captured.last).to eq(captured.first)
      expect(captured.last[:header]).to eq('preserved')
      expect(captured.last[:payload]).to include(
        reasoning_effort: 'high', max_tokens: 512, temperature: 0.25, top_p: 0.8, stop: ['END'], seed: 7,
        tool_choice: { type: 'function', function: { name: 'lookup' } },
        response_format: { type: 'json_schema', json_schema: controls[:schema] }
      )
      expect(captured.last[:payload][:tools]).to eq(
        [{ type: 'function', function: { name: tool.name, description: tool.description, parameters: tool.parameters } }]
      )
      expect(Legion::JSON.dump(wire)).to eq(original)
    end
  end

  { tools: { lookup: 42 }, thinking: [], params: [] }.each do |control, value|
    it "rejects malformed #{control} before provider dispatch and releases the lease" do
      wire = wire_envelope(operation: :chat, controls: { control => value })

      expect { described_class.call(envelope: wire, registry: registry) }
        .to raise_error(Legion::Extensions::Llm::Fleet::ContractError) { |error|
          expect(error.cause).to be_a(ArgumentError)
          expect(Legion::Extensions::Llm::Fleet::ProviderResponder.retryable_error?(error)).to be(false)
        }
      expect(captured).to be_empty
      expect(handle_reference_count).to eq(0)
    end
  end

  it 'preserves explicit nil controls without inventing provider settings' do
    wire = wire_envelope(operation: :chat, controls: { tools: nil, thinking: nil, params: nil })

    described_class.call(envelope: wire, registry: registry)

    expect(captured.first[:payload]).not_to have_key(:tools)
    expect(captured.first[:payload]).not_to have_key(:reasoning_effort)
    expect(captured.first[:payload]).not_to have_key(:max_tokens)
  end

  def wire_envelope(operation:, controls:)
    Legion::JSON.load(Legion::JSON.dump({
                                          provider: key.provider_family, provider_instance: key.instance_id,
                                          model: 'deployment', operation: operation,
                                          offering_id: registry.snapshot.lanes_for(instance_key: key).first.lane_id,
                                          params: { messages: messages }.merge(controls)
                                        }))
  end

  def handle_reference_count
    registry.snapshot.instance(instance_key: key).callable_handle.reference_count
  end
end
