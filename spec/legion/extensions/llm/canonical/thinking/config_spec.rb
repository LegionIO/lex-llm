# frozen_string_literal: true

require 'spec_helper'
require_relative '../../conformance/conformance'

RSpec.describe Legion::Extensions::Llm::Canonical::Thinking::Config do
  subject(:config_class) { described_class }

  let(:type_class) { described_class }
  let(:auto_generated_members) { [] }
  let(:type_source) do
    { enabled: true, effort: 'high', budget: 4096, summary: :concise, metadata: { source: 'client' } }
  end

  it_behaves_like 'a canonical type'

  it 'converts from a plain class to a Data with one name (04 §8)' do
    expect(config_class).to be_a(Class)
    expect(config_class.new(enabled: true, effort: 'low', budget: nil, summary: nil, metadata: {})).to be_a(config_class)
  end

  it 'normalizes symbol effort to String' do
    config = config_class.build(effort: :low)
    expect(config.effort).to eq('low')
  end

  it 'raises on a wrong-class effort' do
    expect { config_class.build(effort: 3) }
      .to raise_error(ArgumentError, /effort expected String, got Integer/)
  end

  describe 'enabled member' do
    it 'defaults to true in .build' do
      config = config_class.build
      expect(config.enabled).to be(true)
    end

    it 'defaults to true in .from_hash when key absent' do
      config = config_class.from_hash({})
      expect(config.enabled).to be(true)
    end

    it 'accepts explicit true' do
      config = config_class.build(enabled: true)
      expect(config.enabled).to be(true)
    end

    it 'accepts explicit false' do
      config = config_class.build(enabled: false)
      expect(config.enabled).to be(false)
    end

    it 'rejects non-boolean in .new' do
      expect { config_class.new(enabled: 'yes', effort: nil, budget: nil, summary: nil, metadata: {}) }
        .to raise_error(ArgumentError, /enabled must be true or false/)
    end

    it 'rejects nil in .new (must be an explicit boolean)' do
      expect { config_class.new(enabled: nil, effort: nil, budget: nil, summary: nil, metadata: {}) }
        .to raise_error(ArgumentError, /enabled must be true or false/)
    end

    it 'enabled? returns the enabled member' do
      expect(config_class.build(enabled: true).enabled?).to be(true)
      expect(config_class.build(enabled: false).enabled?).to be(false)
    end
  end

  describe 'H1/M4 — effort is a closed enum, validated in every constructor' do
    it 'rejects an unrecognized effort in build, from_hash, and .new' do
      expect { config_class.build(effort: 'banana') }
        .to raise_error(ArgumentError, /Invalid effort: "banana"/)
      expect { config_class.from_hash(effort: 'banana') }
        .to raise_error(ArgumentError, /Invalid effort: "banana"/)
      expect { config_class.new(enabled: true, effort: 'banana', budget: nil, summary: nil, metadata: {}) }
        .to raise_error(ArgumentError, /Invalid effort: "banana"/)
    end

    it 'accepts the enum case-insensitively (symbol or string)' do
      expect(config_class.build(effort: :HIGH).effort).to eq('high')
      expect(config_class.new(enabled: true, effort: 'Medium', budget: nil, summary: nil, metadata: {}).effort).to eq('medium')
    end

    it 'accepts all six effort levels' do
      %w[none low medium high xhigh max].each do |level|
        expect(config_class.build(effort: level).effort).to eq(level)
      end
    end

    it 'resolved_budget derives from the validated effort (no silent medium fallback)' do
      expect(config_class.build(effort: 'low').resolved_budget).to eq(1024)
      expect(config_class.build(effort: 'medium').resolved_budget).to eq(8192)
      expect(config_class.build(effort: 'high').resolved_budget).to eq(16_384)
      expect(config_class.build(effort: 'xhigh').resolved_budget).to eq(24_576)
      expect(config_class.build(effort: 'max').resolved_budget).to eq(32_768)
      expect(config_class.build(effort: 'none').resolved_budget).to be_nil
      expect(config_class.build(budget: 123).resolved_budget).to eq(123)
      expect(config_class.build(enabled: false).resolved_budget).to be_nil
    end
  end

  describe 'budget validation' do
    it 'accepts a positive integer' do
      expect(config_class.build(budget: 1).budget).to eq(1)
      expect(config_class.build(budget: 50_000).budget).to eq(50_000)
    end

    it 'accepts nil' do
      expect(config_class.build(budget: nil).budget).to be_nil
    end

    it 'rejects zero' do
      expect { config_class.build(budget: 0) }
        .to raise_error(ArgumentError, /budget must be positive/)
    end

    it 'rejects negative integers' do
      expect { config_class.build(budget: -1) }
        .to raise_error(ArgumentError, /budget must be positive/)
      expect { config_class.build(budget: -100) }
        .to raise_error(ArgumentError, /budget must be positive/)
    end

    it 'rejects non-Integer types' do
      expect { config_class.build(budget: 1.5) }
        .to raise_error(ArgumentError, /budget expected Integer/)
      expect { config_class.build(budget: '1024') }
        .to raise_error(ArgumentError, /budget expected Integer/)
    end
  end

  describe 'summary enum' do
    it 'accepts nil (default)' do
      expect(config_class.build(summary: nil).summary).to be_nil
    end

    it 'accepts :auto, :none, :concise, :detailed' do
      %i[auto none concise detailed].each do |level|
        expect(config_class.build(summary: level).summary).to eq(level)
      end
    end

    it 'coerces string to symbol' do
      expect(config_class.from_hash(summary: 'concise').summary).to eq(:concise)
    end

    it 'rejects invalid summary values' do
      expect { config_class.build(summary: :verbose) }
        .to raise_error(ArgumentError, /Invalid summary/)
      expect { config_class.build(summary: :full) }
        .to raise_error(ArgumentError, /Invalid summary/)
    end

    it 'rejects non-symbol/string types' do
      expect { config_class.build(summary: 42) }
        .to raise_error(ArgumentError, /summary expected Symbol/)
    end
  end

  it 'keeps the effort<->budget SSOT conversions' do
    expect(config_class.build(effort: 'low').resolved_budget).to eq(1024)
    expect(config_class.build(effort: 'medium').resolved_budget).to eq(8192)
    expect(config_class.build(effort: 'high').resolved_budget).to eq(16_384)
    expect(config_class.build(effort: 'xhigh').resolved_budget).to eq(24_576)
    expect(config_class.build(effort: 'max').resolved_budget).to eq(32_768)
    expect(config_class.build(budget: 512).resolved_effort).to eq('low')
    expect(config_class.build(budget: 1024).resolved_effort).to eq('low')
    expect(config_class.build(budget: 8192).resolved_effort).to eq('medium')
    expect(config_class.build(budget: 16_384).resolved_effort).to eq('high')
    expect(config_class.build(budget: 24_576).resolved_effort).to eq('xhigh')
    expect(config_class.build(budget: 32_768).resolved_effort).to eq('max')
    expect(config_class.build(budget: 50_000).resolved_effort).to eq('max')
  end

  describe 'resolved_effort band boundaries' do
    it 'maps budget at boundary to the correct effort level' do
      # At the low boundary
      expect(config_class.build(budget: 1024).resolved_effort).to eq('low')
      # Just above low
      expect(config_class.build(budget: 1025).resolved_effort).to eq('medium')
      # At medium boundary
      expect(config_class.build(budget: 8192).resolved_effort).to eq('medium')
      # Just above medium
      expect(config_class.build(budget: 8193).resolved_effort).to eq('high')
      # At high boundary
      expect(config_class.build(budget: 16_384).resolved_effort).to eq('high')
      # Just above high
      expect(config_class.build(budget: 16_385).resolved_effort).to eq('xhigh')
      # At xhigh boundary
      expect(config_class.build(budget: 24_576).resolved_effort).to eq('xhigh')
      # Just above xhigh
      expect(config_class.build(budget: 24_577).resolved_effort).to eq('max')
    end

    it 'returns nil when budget is nil (no fabrication)' do
      expect(config_class.build.resolved_effort).to be_nil
    end

    it 'returns the supplied effort when both are set (no overwrite)' do
      config = config_class.build(effort: 'low', budget: 30_000)
      expect(config.resolved_effort).to eq('low')
      expect(config.resolved_budget).to eq(30_000)
    end
  end

  it 'to_h is faithful to what was set (no fabricated axis)' do
    expect(config_class.build(effort: 'low').to_h).to eq(enabled: true, effort: 'low', metadata: {})
    # enabled:false is explicit OFF signal — it IS set, so it appears in to_h
    expect(config_class.build(enabled: false).to_h).to eq(enabled: false, metadata: {})
  end

  it 'to_h omits nil members (compact)' do
    config = config_class.build(enabled: true, effort: 'high', budget: 4096, summary: :detailed)
    expect(config.to_h).to eq(enabled: true, effort: 'high', budget: 4096, summary: :detailed, metadata: {})
  end

  it 'from_hash round-trips through to_h' do
    original = config_class.build(enabled: true, effort: 'xhigh', budget: 24_576, summary: :auto)
    rebuilt = config_class.from_hash(original.to_h)
    expect(rebuilt).to eq(original)
  end
end
