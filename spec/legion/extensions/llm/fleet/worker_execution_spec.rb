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

  it 'replaces expired idempotency entries while reserving the new attempt' do
    described_class.instance_variable_get(:@idempotency_keys)['idem-expired'] = {
      state: :complete,
      expires_at: Time.now.to_i - 1
    }

    expect { described_class.reserve_idempotency_key!('idem-expired') }.not_to raise_error

    expect do
      described_class.reserve_idempotency_key!('idem-expired')
    end.to raise_error(described_class::PolicyError, /duplicate fleet idempotency key/)
  end

  it 'reserves token replay protection before provider dispatch and marks success after completion' do
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :auth, :require_signed_token, default: true).and_return(true)
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :responder, :require_idempotency, default: nil).and_return(false)
    allow(Legion::Extensions::Llm::Fleet::TokenValidator).to receive(:validate!).and_return({ jti: 'jti-1' })
    allow(Legion::Extensions::Llm::Fleet::TokenValidator).to receive(:mark_replay!)

    described_class.call(envelope: envelope, provider: provider)

    expect(Legion::Extensions::Llm::Fleet::TokenValidator).to have_received(:validate!)
      .with(token: 'unsigned', envelope: envelope)
    expect(Legion::Extensions::Llm::Fleet::TokenValidator).to have_received(:mark_replay!).with('jti-1')
  end

  it 'releases reserved token replay state when provider dispatch fails' do
    failing_provider = Class.new do
      def chat(**)
        raise 'provider unavailable'
      end
    end.new
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :auth, :require_signed_token, default: true).and_return(true)
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :responder, :require_idempotency, default: nil).and_return(false)
    allow(Legion::Extensions::Llm::Fleet::TokenValidator).to receive(:validate!).and_return({ jti: 'jti-2' })
    allow(Legion::Extensions::Llm::Fleet::TokenValidator).to receive(:release_replay!)

    expect do
      described_class.call(envelope: envelope, provider: failing_provider)
    end.to raise_error(RuntimeError, /provider unavailable/)

    expect(Legion::Extensions::Llm::Fleet::TokenValidator).to have_received(:release_replay!).with('jti-2')
  end
end
