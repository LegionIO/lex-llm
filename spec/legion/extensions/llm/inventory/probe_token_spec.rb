# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/probe_token'

RSpec.describe Legion::Extensions::Llm::Inventory::ProbeToken do
  inventory = Legion::Extensions::Llm::Inventory
  errors = inventory::Errors

  let(:instance_key) { inventory::Identity::InstanceKey.new(provider_family: 'vllm', instance_id: 'h200') }

  it 'issues a frozen, immutable probe token' do
    token = described_class.issue(
      instance_key: instance_key, publisher_token_id: 'ptok:v1:abc', started_availability_revision: 0, started_at: Time.now
    )
    expect(token.token_id).to start_with('probe:v1:')
    expect(token).to be_frozen
  end

  it 'validates its fields' do
    expect do
      described_class.issue(instance_key: instance_key, publisher_token_id: 'nope', started_availability_revision: 0, started_at: Time.now)
    end.to raise_error(errors::ValidationError)
    expect do
      described_class.issue(instance_key: instance_key, publisher_token_id: 'ptok:v1:x', started_availability_revision: -1, started_at: Time.now)
    end.to raise_error(errors::ValidationError)
  end

  describe Legion::Extensions::Llm::Inventory::PublisherToken do
    let(:token) { described_class.issue(instance_key: instance_key) }

    describe '.issue' do
      it 'derives pub:v1: and ptok:v1: correlation IDs and is frozen' do
        expect(token.publisher_id).to start_with('pub:v1:')
        expect(token.publisher_token_id).to start_with('ptok:v1:')
        expect(token).to be_frozen
      end

      it 'derives publisher_token_id from the secret domain-separated SHA-256' do
        other = described_class.issue(instance_key: instance_key)
        expect(token.publisher_token_id).not_to eq(other.publisher_token_id)
      end
    end

    describe 'secret redaction' do
      it 'never exposes the secret through a public reader' do
        expect(token).not_to respond_to(:secret)
      end

      it 'redacts the secret in inspect/to_s' do
        expect(token.inspect).to include('[REDACTED]')
        expect(token.inspect).not_to match(/secret=[0-9a-f]{8}/)
        expect(token.to_s).to include('[REDACTED]')
      end
    end

    describe '#authenticates?' do
      it 'rejects a token with a different secret' do
        other = described_class.issue(instance_key: instance_key)
        expect(token.authenticates?(other)).to be(false)
      end

      it 'rejects a token for a different instance' do
        other_key = inventory::Identity::InstanceKey.new(provider_family: 'vllm', instance_id: 'helios1')
        other = described_class.issue(instance_key: other_key)
        expect(token.authenticates?(other)).to be(false)
      end

      it 'rejects a non-PublisherToken' do
        expect(token.authenticates?(Object.new)).to be(false)
      end

      it 'authenticates two tokens built from the same secret' do
        secret = 'deadbeef' * 8
        token_id = described_class.derive_token_id(secret)
        a = described_class.new(instance_key: instance_key, secret: secret, publisher_id: 'pub:v1:x', publisher_token_id: token_id)
        b = described_class.new(instance_key: instance_key, secret: secret, publisher_id: 'pub:v1:y', publisher_token_id: token_id)
        expect(a.authenticates?(b)).to be(true)
      end
    end

    describe 'validation' do
      it 'rejects a non-InstanceKey and malformed ids' do
        expect { described_class.new(instance_key: :vllm, secret: 'x', publisher_id: 'pub:v1:a', publisher_token_id: 'ptok:v1:a') }
          .to raise_error(errors::ValidationError)
        expect { described_class.new(instance_key: instance_key, secret: 'x', publisher_id: 'bad', publisher_token_id: 'ptok:v1:a') }
          .to raise_error(errors::ValidationError)
      end
    end
  end

  describe Legion::Extensions::Llm::Inventory::ProbeRequest do
    it 'requires a positive unavailable_revision and a ptok:v1: publisher token id' do
      request = described_class.new(instance_key: instance_key, publisher_token_id: 'ptok:v1:x', unavailable_revision: 3, reason: 'dispatch reported unavailable')
      expect(request.unavailable_revision).to eq(3)
      expect { described_class.new(instance_key: instance_key, publisher_token_id: 'ptok:v1:x', unavailable_revision: 0, reason: 'x') }
        .to raise_error(errors::ValidationError)
      expect { described_class.new(instance_key: instance_key, publisher_token_id: 'nope', unavailable_revision: 1, reason: 'x') }
        .to raise_error(errors::ValidationError)
    end

    it 'sanitizes and bounds the reason' do
      expect { described_class.new(instance_key: instance_key, publisher_token_id: 'ptok:v1:x', unavailable_revision: 1, reason: '  ') }
        .to raise_error(errors::ValidationError)
    end
  end
end
