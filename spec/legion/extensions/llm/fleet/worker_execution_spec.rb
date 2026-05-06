# frozen_string_literal: true

require 'legion/extensions/llm/fleet/worker_execution'

RSpec.describe Legion::Extensions::Llm::Fleet::WorkerExecution do
  let(:envelope) do
    {
      operation: :chat,
      model: 'llama3',
      params: { messages: [{ role: 'user', content: 'hello' }] },
      signed_token: 'unsigned',
      idempotency_key: 'idem-1'
    }
  end
  let(:provider) do
    Class.new do
      def chat(messages:, model:, **)
        { content: "#{model}:#{messages.first[:content]}" }
      end
    end.new
  end

  before do
    described_class.reset_idempotency_cache!
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value).and_call_original
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :auth, :require_signed_token, default: true).and_return(false)
  end

  it 'dispatches canonical chat operations directly to the local provider' do
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :responder, :require_idempotency, default: nil).and_return(false)

    expect(described_class.call(envelope: envelope, provider: provider)).to eq(content: 'llama3:hello')
  end

  it 'rejects duplicate idempotency keys before executing the provider again' do
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :responder, :require_idempotency, default: nil).and_return(true)

    described_class.call(envelope: envelope, provider: provider)

    expect do
      described_class.call(envelope: envelope, provider: provider)
    end.to raise_error(described_class::PolicyError, /duplicate fleet idempotency key/)
  end
end
