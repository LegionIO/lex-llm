# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/identity'

RSpec.describe Legion::Extensions::Llm::Inventory::Identity do
  let(:errors) { Legion::Extensions::Llm::Inventory::Errors }
  let(:instance_key_class) { Legion::Extensions::Llm::Inventory::Identity::InstanceKey }

  fixture_path = File.expand_path('../conformance/fixtures/ssot_identity_vectors.json', __dir__)
  fixture = Legion::JSON.load(File.read(fixture_path))

  def hex(binary)
    binary.b.unpack1('H*')
  end

  describe 'binding identity vectors (recomputed field by field)' do
    fixture[:vectors].each_with_index do |vector, index|
      context "with vector #{index}: #{vector[:provider_family]}+#{vector[:instance_id]}" do
        let(:instance_key) do
          instance_key_class.new(
            provider_family: vector[:provider_family],
            instance_id: vector[:instance_id]
          )
        end

        it 'reproduces every framed field as lowercase hex bytes' do
          expect(hex(described_class.length_frame(value: instance_key.provider_family)))
            .to eq(vector[:framed_hex][:provider_family])
          expect(hex(described_class.length_frame(value: instance_key.instance_id)))
            .to eq(vector[:framed_hex][:instance_id])
          expect(hex(described_class.length_frame(value: vector[:provider_native_key])))
            .to eq(vector[:framed_hex][:provider_native_key])
          expect(hex(described_class.length_frame(value: vector[:operation])))
            .to eq(vector[:framed_hex][:operation])
          expect(hex(described_class.length_frame(value: vector[:model])))
            .to eq(vector[:framed_hex][:model])
        end

        it 'reproduces the offering hash input and offering_id' do
          input = described_class.length_frame(value: instance_key.provider_family) +
                  described_class.length_frame(value: instance_key.instance_id) +
                  described_class.length_frame(value: vector[:provider_native_key])
          expect(hex(input)).to eq(vector[:offering_hash_input_hex])

          offering_id = described_class.offering_id(
            instance_key: instance_key, provider_native_key: vector[:provider_native_key]
          )
          expect(offering_id).to eq(vector[:expected_offering_id])
        end

        it 'reproduces the lane hash input and lane_id' do
          offering_id = described_class.offering_id(
            instance_key: instance_key, provider_native_key: vector[:provider_native_key]
          )
          input = "lane-v1\x00".b +
                  described_class.length_frame(value: instance_key.provider_family) +
                  described_class.length_frame(value: instance_key.instance_id) +
                  described_class.length_frame(value: vector[:operation]) +
                  described_class.length_frame(value: vector[:model]) +
                  described_class.length_frame(value: offering_id)
          expect(hex(input)).to eq(vector[:lane_hash_input_hex])

          lane_id = described_class.lane_id(
            instance_key: instance_key,
            operation: vector[:operation].to_sym,
            model: vector[:model],
            offering_id: offering_id
          )
          expect(lane_id).to eq(vector[:expected_lane_id])
        end

        it 'validates the reproduced offering_id and lane_id' do
          offering_id = vector[:expected_offering_id]
          expect(
            described_class.validate_offering_id!(
              value: offering_id, instance_key: instance_key, provider_native_key: vector[:provider_native_key]
            )
          ).to eq(offering_id)
          expect(
            described_class.validate_lane_id!(
              value: vector[:expected_lane_id], instance_key: instance_key,
              operation: vector[:operation].to_sym, model: vector[:model], offering_id: offering_id
            )
          ).to eq(vector[:expected_lane_id])
        end
      end
    end
  end

  describe 'independence and delimiter safety' do
    it 'produces distinct offering/lane IDs for the same model on two instance IDs' do
      expect(fixture[:vectors][0][:expected_offering_id]).not_to eq(fixture[:vectors][1][:expected_offering_id])
      expect(fixture[:vectors][0][:expected_lane_id]).not_to eq(fixture[:vectors][1][:expected_lane_id])
    end

    it 'is tier-independent: tier is never a framing input' do
      vector = fixture[:vectors][0]
      instance_key = instance_key_class.new(provider_family: vector[:provider_family], instance_id: vector[:instance_id])
      %i[local frontier].each do |_tier|
        offering_id = described_class.offering_id(
          instance_key: instance_key, provider_native_key: vector[:provider_native_key]
        )
        expect(offering_id).to eq(vector[:expected_offering_id])
        expect(
          described_class.lane_id(
            instance_key: instance_key, operation: vector[:operation].to_sym,
            model: vector[:model], offering_id: offering_id
          )
        ).to eq(vector[:expected_lane_id])
      end
    end

    it 'frames punctuation inside a component without delimiter ambiguity' do
      vector = fixture[:vectors][2]
      instance_key = instance_key_class.new(provider_family: vector[:provider_family], instance_id: vector[:instance_id])
      expect(instance_key.instance_id).to eq('prod:eastus')
      expect(
        described_class.offering_id(instance_key: instance_key, provider_native_key: vector[:provider_native_key])
      ).to eq(vector[:expected_offering_id])
    end
  end

  describe '.length_frame' do
    it 'is decimal byte length + ASCII colon + exact UTF-8 bytes, in binary' do
      frame = described_class.length_frame(value: 'gemma4')
      expect(frame.encoding).to eq(Encoding::BINARY)
      expect(frame).to eq('6:gemma4'.b)
    end

    it 'counts UTF-8 bytes, not characters' do
      composed = [0x00e9].pack('U*') # single codepoint => two UTF-8 bytes
      expect(described_class.length_frame(value: composed)).to eq('2:'.b + composed.b)
    end
  end

  describe '.normalize_text' do
    it 'accepts String and Symbol and returns a frozen UTF-8 String' do
      result = described_class.normalize_text(value: :vllm, field: :provider_family)
      expect(result).to eq('vllm')
      expect(result).to be_frozen
    end

    it 'trims surrounding whitespace' do
      expect(described_class.normalize_text(value: '  h200  ', field: :instance_id)).to eq('h200')
    end

    it 'rejects empty and whitespace-only values' do
      expect { described_class.normalize_text(value: '   ', field: :f) }.to raise_error(errors::ValidationError)
      expect { described_class.normalize_text(value: '', field: :f) }.to raise_error(errors::ValidationError)
    end

    it 'rejects invalid UTF-8' do
      expect { described_class.normalize_text(value: "\xFF".b, field: :f) }.to raise_error(errors::ValidationError)
    end

    it 'rejects a non-NFC (decomposed) string' do
      decomposed = [0x0065, 0x0301].pack('U*') # e + combining acute; not NFC
      expect { described_class.normalize_text(value: decomposed, field: :f) }
        .to raise_error(errors::ValidationError, /NFC/)
    end

    it 'rejects a non-text type' do
      expect { described_class.normalize_text(value: 5, field: :f) }.to raise_error(errors::ValidationError)
    end
  end

  describe '.normalize_enum' do
    it 'returns an allowed symbol' do
      expect(described_class.normalize_enum(value: 'local', field: :tier, allowed: %i[local frontier])).to eq(:local)
    end

    it 'rejects a value not in the allowed set' do
      expect { described_class.normalize_enum(value: :nope, field: :tier, allowed: %i[local]) }
        .to raise_error(errors::ValidationError)
    end
  end

  describe 'InstanceKey' do
    it 'downcases provider_family to a Symbol and preserves instance_id case' do
      key = instance_key_class.new(provider_family: 'Azure_Foundry', instance_id: 'Prod:EastUS')
      expect(key.provider_family).to eq(:azure_foundry)
      expect(key.instance_id).to eq('Prod:EastUS')
    end

    it 'exposes to_h with the two fields' do
      key = instance_key_class.new(provider_family: :vllm, instance_id: 'h200')
      expect(key.to_h).to eq(provider_family: :vllm, instance_id: 'h200')
    end

    it 'is value-equal for equal normalized fields' do
      a = instance_key_class.new(provider_family: 'vllm', instance_id: 'h200')
      b = instance_key_class.new(provider_family: :vllm, instance_id: '  h200 ')
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it 'rejects a provider_family that is not snake-case ASCII' do
      expect { instance_key_class.new(provider_family: '1bad', instance_id: 'x') }
        .to raise_error(errors::ValidationError)
      expect { instance_key_class.new(provider_family: 'has space', instance_id: 'x') }
        .to raise_error(errors::ValidationError)
    end

    it 'rejects the reserved instance_id "default"' do
      expect { instance_key_class.new(provider_family: 'vllm', instance_id: 'default') }
        .to raise_error(errors::ValidationError)
    end

    it 'rejects nil fields' do
      expect { instance_key_class.new(provider_family: nil, instance_id: 'x') }
        .to raise_error(errors::ValidationError)
      expect { instance_key_class.new(provider_family: 'vllm', instance_id: nil) }
        .to raise_error(errors::ValidationError)
    end
  end

  describe 'public surface' do
    it 'exposes exactly the seven documented module methods' do
      expected = %i[
        normalize_text normalize_enum length_frame offering_id lane_id
        validate_offering_id! validate_lane_id!
      ].sort
      expect(described_class.singleton_methods(false).sort).to eq(expected)
    end
  end
end
