# frozen_string_literal: true

require 'legion/crypt'
require 'legion/extensions/llm/fleet/token_validator'

RSpec.describe Legion::Extensions::Llm::Fleet::TokenValidator do
  let(:expires_at) { (Time.now.utc + 60).iso8601 }
  let(:envelope) do
    {
      request_id: 'req-1',
      correlation_id: 'corr-1',
      idempotency_key: 'idem-1',
      operation: :chat,
      provider: :ollama,
      provider_instance: :default,
      model: 'llama3',
      reply_to: 'reply.queue',
      message_context: { conversation_id: 'conv-1' },
      params: { messages: [{ role: 'user', content: 'hello' }] },
      caller: { identity: 'user:matt' },
      trace_context: { trace_id: 'trace-1' },
      timeout_seconds: 30,
      expires_at: expires_at
    }
  end
  let(:claims) do
    envelope.merge(
      iss: 'legion-llm',
      aud: 'lex-llm-fleet-worker',
      exp: Time.now.to_i + 60,
      nbf: Time.now.to_i - 1,
      jti: 'jti-1'
    )
  end

  before do
    described_class.reset_replay_cache!
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value).and_call_original
    allow(Legion::Crypt).to receive(:cluster_secret).and_return('secret')
    allow(Legion::Crypt::JWT).to receive(:verify).and_return(claims)
  end

  it 'verifies the signed token and validates matching envelope claims' do
    expect(validate_token).to include(jti: 'jti-1')
    expect(Legion::Crypt::JWT).to have_received(:verify).with(
      'signed.jwt',
      verification_key: 'secret',
      issuer: 'legion-llm',
      algorithm: 'HS256',
      verify_issuer: false
    )
  end

  it 'rejects missing tokens' do
    expect do
      described_class.validate!(token: nil, envelope: envelope)
    end.to raise_error(Legion::Extensions::Llm::Fleet::TokenError, /token is required/)
  end

  {
    iss: ['other-issuer', /issuer mismatch/],
    aud: ['wrong-audience', /audience mismatch/],
    exp: [Time.now.to_i - 300, /token expired/],
    nbf: [Time.now.to_i + 300, /not yet valid/],
    jti: ['', /missing jti/]
  }.each do |claim, (value, message)|
    it "rejects invalid registered claim #{claim}" do
      allow(Legion::Crypt::JWT).to receive(:verify).and_return(claims.merge(claim => value))

      expect { validate_token }.to raise_error(Legion::Extensions::Llm::Fleet::TokenError, message)
    end
  end

  it 'rejects expired request envelopes' do
    allow(Legion::Crypt::JWT).to receive(:verify)
      .and_return(claims.merge(expires_at: (Time.now.utc - 31).iso8601))

    expect { validate_token }.to raise_error(Legion::Extensions::Llm::Fleet::TokenError, /request expired/)
  end

  it 'rejects invalid request expiry timestamps' do
    allow(Legion::Crypt::JWT).to receive(:verify).and_return(claims.merge(expires_at: 'not-time'))

    expect { validate_token }.to raise_error(Legion::Extensions::Llm::Fleet::TokenError, /expires_at is invalid/)
  end

  %i[
    request_id correlation_id idempotency_key operation provider provider_instance model reply_to message_context params
    caller trace_context timeout_seconds expires_at
  ].each do |claim|
    it "rejects envelope claim mismatch for #{claim}" do
      value = claim == :expires_at ? (Time.now.utc + 120).iso8601 : 'different'
      allow(Legion::Crypt::JWT).to receive(:verify).and_return(claims.merge(claim => value))

      expect do
        validate_token
      end.to raise_error(Legion::Extensions::Llm::Fleet::TokenError, /#{claim} claim mismatch/)
    end
  end

  it 'wraps JWT verification failures with a token validation error' do
    allow(Legion::Crypt::JWT).to receive(:verify).and_raise(StandardError, 'bad signature')

    expect do
      validate_token
    end.to raise_error(Legion::Extensions::Llm::Fleet::TokenError, /verification failed: bad signature/)
  end

  it 'reserves replay tokens immediately and rejects duplicate validation' do
    validate_token

    expect { validate_token }.to raise_error(Legion::Extensions::Llm::Fleet::TokenError, /replay detected/)
  end

  it 'supports non-recording validation while still rejecting already recorded tokens' do
    expect(validate_token(record_replay: false)).to include(jti: 'jti-1')
    expect(validate_token(record_replay: false)).to include(jti: 'jti-1')

    validate_token

    expect do
      validate_token(record_replay: false)
    end.to raise_error(Legion::Extensions::Llm::Fleet::TokenError, /replay detected/)
  end

  it 'can release inflight replay reservations after failed dispatch' do
    validate_token
    described_class.release_replay!('jti-1')

    expect(validate_token).to include(jti: 'jti-1')
  end

  it 'keeps completed replay reservations after release is requested' do
    validate_token
    described_class.mark_replay!('jti-1')
    described_class.release_replay!('jti-1')

    expect do
      validate_token(record_replay: false)
    end.to raise_error(Legion::Extensions::Llm::Fleet::TokenError, /replay detected/)
  end

  it 'uses a dedicated auth replay TTL setting' do
    allow(Legion::Extensions::Llm::Fleet::Settings).to receive(:value)
      .with(:fleet, :auth, :replay_ttl_seconds, default: 600).and_return(42)

    expect(described_class.replay_ttl_seconds).to eq(42)
  end

  def validate_token(record_replay: true)
    described_class.validate!(token: 'signed.jwt', envelope: envelope, record_replay: record_replay)
  end
end
