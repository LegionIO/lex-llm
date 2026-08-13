# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/immutable_value'

RSpec.describe Legion::Extensions::Llm::Inventory::ImmutableValue do
  subject(:copy) { described_class.copy_and_freeze(value: value, field: :meta) }

  describe 'scalar passthrough' do
    it 'returns nil, booleans, symbols, and integers unchanged' do
      [nil, true, false, :sym, 0, -5, 2**80].each do |scalar|
        expect(described_class.copy_and_freeze(value: scalar, field: :f)).to eq(scalar)
      end
    end

    it 'accepts finite floats' do
      expect(described_class.copy_and_freeze(value: 1.5, field: :f)).to eq(1.5)
    end

    it 'rejects NaN' do
      expect { described_class.copy_and_freeze(value: (0.0 / 0.0), field: :f) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError, /f is not a finite Float/)
    end

    it 'rejects positive and negative infinity' do
      expect { described_class.copy_and_freeze(value: (1.0 / 0.0), field: :f) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
      expect { described_class.copy_and_freeze(value: (-1.0 / 0.0), field: :f) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError)
    end
  end

  describe 'strings' do
    let(:value) { +'hello' }

    it 'returns a frozen copy' do
      expect(copy).to eq('hello')
      expect(copy).to be_frozen
    end

    it 'does not retain the original mutable reference' do
      original = +'mutable'
      result = described_class.copy_and_freeze(value: original, field: :f)
      expect(result).not_to equal(original)
    end

    it 'rejects invalid UTF-8' do
      bad = "\xFF\xFE".b
      expect { described_class.copy_and_freeze(value: bad, field: :f) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError, /not valid UTF-8/)
    end
  end

  describe 'Time' do
    let(:value) { Time.now }

    it 'duplicates and freezes' do
      original = Time.now
      result = described_class.copy_and_freeze(value: original, field: :f)
      expect(result).to eq(original)
      expect(result).to be_frozen
      expect(result).not_to equal(original)
    end
  end

  describe 'arrays and hashes' do
    it 'deeply freezes nested arrays preserving order' do
      result = described_class.copy_and_freeze(value: [3, [2, [1]]], field: :f)
      expect(result).to eq([3, [2, [1]]])
      expect(result).to be_frozen
      expect(result[1]).to be_frozen
      expect(result[1][1]).to be_frozen
    end

    it 'deeply freezes nested hashes and preserves insertion order' do
      result = described_class.copy_and_freeze(value: { b: 1, a: { c: [1] } }, field: :f)
      expect(result.keys).to eq(%i[b a])
      expect(result).to be_frozen
      expect(result[:a]).to be_frozen
      expect(result[:a][:c]).to be_frozen
    end

    it 'accepts String and Symbol hash keys and freezes String keys' do
      result = described_class.copy_and_freeze(value: { 'x' => 1, y: 2 }, field: :f)
      expect(result.keys.map(&:frozen?)).to all(be(true))
    end

    it 'rejects a non-String/Symbol hash key' do
      expect { described_class.copy_and_freeze(value: { 1 => :v }, field: :f) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError, %r{non-String/Symbol key})
    end

    it 'does not retain nested mutable references from the original' do
      inner = +'inner'
      original = { list: [inner] }
      result = described_class.copy_and_freeze(value: original, field: :f)
      inner << '-mutated'
      expect(result[:list].first).to eq('inner')
    end
  end

  describe 'rejections' do
    it 'rejects an unsupported object' do
      expect { described_class.copy_and_freeze(value: Object.new, field: :f) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError, /unsupported value type/)
    end

    it 'rejects a callable' do
      expect { described_class.copy_and_freeze(value: -> { 1 }, field: :f) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError, /unsupported value type/)
    end

    it 'rejects a cyclic array naming the field path' do
      cyclic = []
      cyclic << cyclic
      expect { described_class.copy_and_freeze(value: cyclic, field: :meta) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError, /meta.*cyclic/)
    end

    it 'rejects a cyclic hash' do
      cyclic = {}
      cyclic[:self] = cyclic
      expect { described_class.copy_and_freeze(value: cyclic, field: :meta) }
        .to raise_error(Legion::Extensions::Llm::Inventory::Errors::ValidationError, /cyclic/)
    end

    it 'allows the same non-cyclic object referenced twice' do
      shared = { k: 1 }
      expect { described_class.copy_and_freeze(value: [shared, shared], field: :f) }.not_to raise_error
    end
  end
end
