# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'

RSpec.describe Legion::Extensions::Llm::Fleet::ProviderResponder do
  let(:protocol) { Legion::Extensions::Llm::Fleet::Protocol }
  let(:payload) do
    {
      request_id: 'req-1',
      correlation_id: 'corr-1',
      idempotency_key: 'idem-1',
      operation: :chat,
      provider: :ollama,
      provider_instance: :default,
      model: 'llama3',
      params: { messages: [{ role: 'user', content: 'hello' }], temperature: 0.1 },
      reply_to: 'reply.queue',
      message_context: { conversation_id: 'conv-1' },
      caller: { identity: 'user:matt' },
      trace_context: { trace_id: 'trace-1' },
      signed_token: 'unsigned',
      timeout_seconds: 30,
      expires_at: (Time.now.utc + 30).iso8601,
      protocol_version: protocol::VERSION
    }
  end
  let(:provider_instances) do
    {
      default: {
        base_url: 'http://localhost:11434',
        fleet: { respond_to_requests: true }
      }
    }
  end
  let(:provider_class) do
    Class.new do
      attr_reader :settings

      def initialize(settings)
        @settings = settings
      end

      def chat(messages:, model:, **params)
        {
          content: "chat #{model} #{messages.first[:content]}",
          usage: { input_tokens: 1, output_tokens: 2 },
          metadata: { temperature: params[:temperature], base_url: settings[:base_url] }
        }
      end
    end
  end

  before do
    Legion::Extensions::Llm::Fleet::WorkerExecution.reset_idempotency_cache!
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value).and_call_original
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :auth, :require_signed_token, default: true).and_return(false)
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :responder, :require_idempotency, default: nil).and_return(false)
  end

  it 'does not require the legion-llm namespace on responder nodes' do
    hide_const('Legion::LLM') if defined?(Legion::LLM)

    expect(defined?(Legion::LLM)).to be_nil
    expect(described_class).to respond_to(:call)
  end

  it 'builds a provider from the requested instance, dispatches the operation, and publishes a fleet response' do
    response_message = instance_double(Legion::Extensions::Llm::Transport::Messages::FleetResponse, publish: true)
    allow(Legion::Extensions::Llm::Transport::Messages::FleetResponse).to receive(:new).and_return(response_message)

    response = described_class.call(
      payload: payload,
      provider_family: :ollama,
      provider_class: provider_class,
      provider_instances: provider_instances
    )

    expect(response).to include(content: 'chat llama3 hello')
    expect(Legion::Extensions::Llm::Transport::Messages::FleetResponse).to have_received(:new).with(
      hash_including(
        request_id: 'req-1',
        correlation_id: 'corr-1',
        provider: :ollama,
        provider_instance: :default,
        model: 'llama3',
        content: 'chat llama3 hello',
        usage: { input_tokens: 1, output_tokens: 2 },
        metadata: { temperature: 0.1, base_url: 'http://localhost:11434' }
      )
    )
    expect(response_message).to have_received(:publish)
  end

  it 'rejects legacy fleet protocol fields before provider execution' do
    expect do
      described_class.call(
        payload: payload.merge(request_type: 'chat'),
        provider_family: :ollama,
        provider_class: provider_class,
        provider_instances: provider_instances
      )
    end.to raise_error(ArgumentError, /request_type/)
  end

  it 'reports whether a provider instance is enabled for fleet responses' do
    expect(described_class.enabled_for?(provider_instances)).to be(true)
    expect(described_class.enabled_for?(default: { fleet: { respond_to_requests: false } })).to be(false)
  end
end
