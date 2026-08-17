# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/routing/provider_outcome'

RSpec.describe Legion::Extensions::Llm::Routing::ProviderOutcome do
  inventory = Legion::Extensions::Llm::Inventory
  routing = Legion::Extensions::Llm::Routing
  errors = inventory::Errors

  it 'builds a normalized outcome for each canonical kind' do
    outcome = described_class.new(kind: :success, reason: 'ok')
    expect(outcome.kind).to eq(:success)
    expect(outcome.metadata).to be_frozen
  end

  it 'rejects a kind outside PROVIDER_OUTCOMES' do
    expect { described_class.new(kind: :made_up, reason: 'x') }.to raise_error(errors::ValidationError)
  end

  it 'has no HTTP status field: 503/529 cannot be an input' do
    expect(described_class.members).not_to include(:http_status, :status_code)
    expect(described_class.new(kind: :overloaded, reason: '503 overloaded').kind).to eq(:overloaded)
  end

  it 'never manufactures instance_unavailable from a raw status; only an explicit kind does' do
    # An adapter that received HTTP 503 overload constructs :overloaded, not :instance_unavailable.
    overloaded = described_class.new(kind: :overloaded, reason: 'HTTP 503 overloaded')
    expect(overloaded.kind).not_to eq(:instance_unavailable)
    # instance_unavailable exists only when an adapter explicitly constructs that kind.
    explicit = described_class.new(kind: :instance_unavailable, reason: 'service unavailable')
    expect(explicit.kind).to eq(:instance_unavailable)
  end

  it 'allows a quota_domain only for rate_limited' do
    domain = routing::QuotaDomainKey.new(provider_family: 'vllm', opaque_id: 'q1')
    expect(described_class.new(kind: :rate_limited, reason: 'quota', quota_domain: domain).quota_domain).to eq(domain)
    expect { described_class.new(kind: :timeout, reason: 'x', quota_domain: domain) }
      .to raise_error(errors::ValidationError)
  end

  it 'requires quota_domain to be a QuotaDomainKey' do
    expect { described_class.new(kind: :rate_limited, reason: 'x', quota_domain: 'q1') }
      .to raise_error(errors::ValidationError)
  end

  it 'accepts a finite nonnegative retry_after and rejects negatives/infinity' do
    expect(described_class.new(kind: :rate_limited, reason: 'x', retry_after: 1.5).retry_after).to eq(1.5)
    expect { described_class.new(kind: :rate_limited, reason: 'x', retry_after: -1) }
      .to raise_error(errors::ValidationError)
    expect { described_class.new(kind: :rate_limited, reason: 'x', retry_after: (1.0 / 0.0)) }
      .to raise_error(errors::ValidationError)
  end

  it 'rejects secret metadata' do
    expect { described_class.new(kind: :success, reason: 'ok', metadata: { api_key: 'x' }) }
      .to raise_error(errors::ValidationError)
  end

  it 'coerces a non-UTF-8 (binary) provider error reason to valid UTF-8 instead of raising' do
    # Regression guard (root cause A): RecordSupport.sanitized_reason previously raised
    # ValidationError 'is not valid UTF-8' on an ASCII-8BIT/BINARY reason (a raw provider
    # error body or Ruby kernel error message), masking the real dispatch error as an
    # unclassifiable retriable 500. It now coerces to valid UTF-8 (undecodable bytes
    # replaced), so a provider error can no longer mask itself.
    raw = "provider 500 \xFF\x80 body".dup.force_encoding(Encoding::BINARY)
    expect { described_class.new(kind: :provider_error, reason: raw) }.not_to raise_error

    outcome = described_class.new(kind: :provider_error, reason: raw)
    expect(outcome.kind).to eq(:provider_error)
    expect(outcome.reason.valid_encoding?).to be(true)
  end
end
