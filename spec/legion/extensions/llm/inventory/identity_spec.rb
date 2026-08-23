# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/identity'

RSpec.describe Legion::Extensions::Llm::Inventory::Identity do
  let(:errors) { Legion::Extensions::Llm::Inventory::Errors }
  let(:instance_key_class) { Legion::Extensions::Llm::Inventory::Identity::InstanceKey }
  let(:taxonomies) { Legion::Extensions::Llm::Taxonomies }

  def compose(tier: :local, family: 'vllm', instance: 'h200', type: :inference, model: 'gemma4')
    described_class.compose_lane_id(
      tier: tier, provider_family: family, instance_id: instance, type: type, model: model
    )
  end

  describe 'compose_lane_id (the ONE 5-tuple composer, G22)' do
    it 'joins tier:provider_family:instance_id:type:model exactly' do
      expect(compose).to eq('local:vllm:h200:inference:gemma4')
    end

    it 'is byte-identical to the v0.6.16 ScopedRefresher.compose_id shape' do
      lane_fields = { tier: 'frontier', provider_family: 'openai', instance_id: 'prod', type: 'embedding', model: 'text-embed-3' }
      expected = "#{lane_fields[:tier]}:#{lane_fields[:provider_family]}:#{lane_fields[:instance_id]}:#{lane_fields[:type]}:#{lane_fields[:model]}"
      expect(
        described_class.compose_lane_id(
          tier: lane_fields[:tier], provider_family: lane_fields[:provider_family],
          instance_id: lane_fields[:instance_id], type: lane_fields[:type], model: lane_fields[:model]
        )
      ).to eq(expected)
    end

    it 'preserves colons inside the model part (Ollama model:tag, Bedrock ids)' do
      id = compose(family: 'ollama', instance: 'apollo', model: 'llama3.2:8b-instruct')
      expect(id).to eq('local:ollama:apollo:inference:llama3.2:8b-instruct')

      bedrock = compose(family: 'bedrock', instance: 'us-east-1', type: :inference, model: 'anthropic.claude-opus-4-7:0')
      expect(bedrock).to eq('local:bedrock:us-east-1:inference:anthropic.claude-opus-4-7:0')
    end

    it 'round-trips through parse_lane_id for every type and tier' do
      taxonomies::TYPES.each do |type|
        taxonomies::TIERS.each do |tier|
          id = compose(tier: tier, type: type, model: 'model:tag:v1')
          expect(described_class.parse_lane_id(id)).to eq(
            [tier.to_s, 'vllm', 'h200', type.to_s, 'model:tag:v1']
          )
          expect(described_class.validate_lane_id!(value: id)).to eq(id)
        end
      end
    end
  end

  describe 'parse_lane_id (bounded split — the 5th part keeps its colons)' do
    it 'returns exactly five parts with the model keeping its colons' do
      expect(described_class.parse_lane_id('local:vllm:h200:inference:a:b:c')).to eq(
        %w[local vllm h200 inference a:b:c]
      )
    end

    it 'accepts a Symbol input' do
      expect(described_class.parse_lane_id(:'local:vllm:h200:inference:gemma4')).to eq(
        %w[local vllm h200 inference gemma4]
      )
    end

    it 'rejects fewer than five parts' do
      expect { described_class.parse_lane_id('local:vllm:h200:inference') }
        .to raise_error(errors::ValidationError, /exactly 5 parts, got 4/)
    end

    it 'never returns more than five parts (colons do not split further)' do
      expect(described_class.parse_lane_id('local:vllm:h200:inference:x:y').length).to eq(5)
    end

    it 'rejects non-text input' do
      expect { described_class.parse_lane_id(123) }.to raise_error(errors::ValidationError)
    end
  end

  describe 'validate_lane_id!' do
    it 'accepts a well-formed 5 tuple and returns it unchanged' do
      expect(described_class.validate_lane_id!(value: 'cloud:gemini:default:audio:speech-2')).to eq('cloud:gemini:default:audio:speech-2')
    end

    it 'rejects any non-5-tuple value on the plain shape check alone' do
      expect { described_class.validate_lane_id!(value: 'weird:identity') }
        .to raise_error(errors::ValidationError, /exactly 5 parts, got 2/)
      expect { described_class.validate_lane_id!(value: 'a:b:c:d') }
        .to raise_error(errors::ValidationError, /exactly 5 parts, got 4/)
    end

    it 'rejects a tier outside Taxonomies::TIERS' do
      expect { described_class.validate_lane_id!(value: 'bogus:vllm:h200:inference:gemma4') }
        .to raise_error(errors::ValidationError, /tier/)
    end

    it 'rejects a type outside Taxonomies::TYPES' do
      expect { described_class.validate_lane_id!(value: 'local:vllm:h200:moderation:gemma4') }
        .to raise_error(errors::ValidationError, /type/)
    end

    it 'rejects an empty provider_family or instance_id' do
      expect { described_class.validate_lane_id!(value: 'local::h200:inference:gemma4') }
        .to raise_error(errors::ValidationError, /provider_family/)
      expect { described_class.validate_lane_id!(value: 'local:vllm::inference:gemma4') }
        .to raise_error(errors::ValidationError, /instance_id/)
    end

    it 'rejects an empty model' do
      expect { described_class.validate_lane_id!(value: 'local:vllm:h200:inference:') }
        .to raise_error(errors::ValidationError, /model/)
    end

    it 'rejects a non-NFC provider_family, instance_id, or model' do
      decomposed = [0x0065, 0x0301].pack('U*') # e + combining acute; not NFC
      expect { described_class.validate_lane_id!(value: "local:#{decomposed}vllm:h200:inference:gemma4") }
        .to raise_error(errors::ValidationError, /provider_family/)
      expect { described_class.validate_lane_id!(value: "local:vllm:#{decomposed}h200:inference:gemma4") }
        .to raise_error(errors::ValidationError, /instance_id/)
      expect { described_class.validate_lane_id!(value: "local:vllm:h200:inference:#{decomposed}emma4") }
        .to raise_error(errors::ValidationError, /model/)
    end
  end

  describe 'independence' do
    it 'produces distinct ids for the same model on two instance ids' do
      expect(compose(instance: 'h200')).not_to eq(compose(instance: 'helios1'))
    end

    it 'is tier-SENSITIVE: the tier is the first id part (unlike the deleted digest)' do
      expect(compose(tier: :local)).not_to eq(compose(tier: :frontier))
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

    it 'exposes to_h with the three fields (physical_id nil by default)' do
      key = instance_key_class.new(provider_family: :vllm, instance_id: 'h200')
      expect(key.to_h).to eq(provider_family: :vllm, instance_id: 'h200', physical_id: nil)
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

    it 'accepts "default" as a plain instance_id label (no reserved values — v2 parity)' do
      key = instance_key_class.new(provider_family: 'vllm', instance_id: 'default')
      expect(key.instance_id).to eq('default')

      other = instance_key_class.new(provider_family: 'vllm', instance_id: '  default ')
      expect(key).to eq(other)
      expect(key.hash).to eq(other.hash)

      expect(key.to_h).to eq(provider_family: :vllm, instance_id: 'default', physical_id: nil)
      expect(key.inspect).to include('instance_id="default"')
    end

    it 'rejects nil fields' do
      expect { instance_key_class.new(provider_family: nil, instance_id: 'x') }
        .to raise_error(errors::ValidationError)
      expect { instance_key_class.new(provider_family: 'vllm', instance_id: nil) }
        .to raise_error(errors::ValidationError)
    end

    it 'keeps the two-argument constructor working (physical_id defaults to nil)' do
      key = instance_key_class.new(provider_family: :vllm, instance_id: 'apollo')
      expect(key.physical_id).to be_nil
    end

    describe 'physical_id (secondary, not identity)' do
      it 'normalizes like identity text: trims, NFC, frozen String' do
        key = instance_key_class.new(provider_family: :vllm, instance_id: 'apollo', physical_id: '  10.0.0.1:8000/ak:abc123 ')
        expect(key.physical_id).to eq('10.0.0.1:8000/ak:abc123')
        expect(key.physical_id).to be_frozen
      end

      it 'preserves the physical id for diagnostics while identity stays the config name' do
        key = instance_key_class.new(
          provider_family: :vllm, instance_id: 'apollo', physical_id: '10.0.0.1:8000/ak:abc123'
        )
        expect(key.instance_id).to eq('apollo')
        expect(key.physical_id).to eq('10.0.0.1:8000/ak:abc123')
      end

      it 'excludes physical_id from equality and hashing' do
        bare = instance_key_class.new(provider_family: :vllm, instance_id: 'apollo')
        with_physical = instance_key_class.new(
          provider_family: :vllm, instance_id: 'apollo', physical_id: '10.0.0.1:8000/ak:abc123'
        )
        other_physical = instance_key_class.new(
          provider_family: :vllm, instance_id: 'apollo', physical_id: '10.0.0.9:9000'
        )
        expect(bare).to eq(with_physical)
        expect(bare.hash).to eq(other_physical.hash)
        expect({ bare => :found }[with_physical]).to eq(:found)
      end

      it 'accepts "default" for physical_id (no field is reserved)' do
        key = instance_key_class.new(provider_family: :vllm, instance_id: 'apollo', physical_id: 'default')
        expect(key.physical_id).to eq('default')
      end

      it 'rejects a blank or non-text physical_id' do
        expect { instance_key_class.new(provider_family: 'vllm', instance_id: 'x', physical_id: '   ') }
          .to raise_error(errors::ValidationError)
        expect { instance_key_class.new(provider_family: 'vllm', instance_id: 'x', physical_id: 5) }
          .to raise_error(errors::ValidationError)
      end

      it 'still distinguishes distinct config names on the same physical endpoint' do
        apollo = instance_key_class.new(provider_family: 'ollama', instance_id: 'apollo', physical_id: 'localhost:11434')
        apollo_embed = instance_key_class.new(provider_family: 'ollama', instance_id: 'apollo-embed', physical_id: 'localhost:11434')
        expect(apollo).not_to eq(apollo_embed)
      end
    end
  end

  describe 'M6 — the single config→instance-id derivation (owner law)' do
    it 'derives the operator config name from a provider config' do
      config = Struct.new(:instance_id).new('h200')
      expect(described_class.instance_id(config)).to eq('h200')
    end

    it 'uses the ordinary "default" label (not a reserved value) when no instance name is configured' do
      expect(described_class.instance_id(Struct.new(:instance_id).new(nil))).to eq('default')
      expect(described_class.instance_id({})).to eq('default')
      expect(described_class.instance_id(nil)).to eq('default')
    end
  end

  describe 'public surface' do
    it 'exposes exactly the documented module methods — no digest machinery' do
      expected = %i[
        normalize_text normalize_enum compose_lane_id parse_lane_id
        validate_lane_id! instance_id
      ].sort
      expect(described_class.singleton_methods(false).sort).to eq(expected)
    end

    it 'defines no digest encoder or legacy validator' do
      %i[length_frame offering_id lane_id validate_offering_id!].each do |gone|
        expect(described_class.singleton_methods(false)).not_to include(gone)
      end
    end
  end
end
