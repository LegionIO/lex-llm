# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::CapabilityPolicy do
  let(:empty_sources) do
    { real: {}, provider_catalog: {}, probe: {}, provider_envelope: {}, provider_config: {}, instance_config: {},
      model_config: {} }
  end

  describe '.resolve' do
    context 'with no data at all' do
      it 'defaults all optional capabilities to false' do
        policy = described_class.resolve(**empty_sources)

        expect(policy[:capabilities]).to eq([])
        expect(policy[:sources][:embedding]).to eq(value: false, source: :default_false)
        expect(policy[:sources][:thinking]).to eq(value: false, source: :default_false)
        expect(policy[:sources][:streaming]).to eq(value: false, source: :default_false)
        expect(policy[:sources][:tools]).to eq(value: false, source: :default_false)
        expect(policy[:sources][:vision]).to eq(value: false, source: :default_false)
      end
    end

    context 'with instance override' do
      it 'resolves capabilities from instance config' do
        policy = described_class.resolve(
          real: {},
          provider_catalog: {},
          probe: {},
          provider_envelope: {},
          provider_config: {
            capabilities: { embeddings: false },
            tools_flag: false
          },
          instance_config: {
            capabilities: { streaming: true, tools: true },
            enable_thinking: true
          },
          model_config: {}
        )

        expect(policy[:capabilities]).to contain_exactly(:streaming, :tools, :thinking)
        expect(policy[:sources][:thinking]).to eq(value: true, source: :instance_override)
        expect(policy[:sources][:embedding]).to eq(value: false, source: :provider_override)
        expect(policy[:sources][:tools]).to eq(value: true, source: :instance_override)
      end
    end

    context 'with provider-level override' do
      it 'resolves capabilities from provider config' do
        policy = described_class.resolve(
          real: {},
          provider_catalog: {},
          probe: {},
          provider_envelope: {},
          provider_config: {
            capabilities: { streaming: true },
            embedding_flag: false,
            thinking_flag: true
          },
          instance_config: {},
          model_config: {}
        )

        expect(policy[:capabilities]).to contain_exactly(:streaming, :thinking)
        expect(policy[:sources][:streaming]).to eq(value: true, source: :provider_override)
        expect(policy[:sources][:embedding]).to eq(value: false, source: :provider_override)
        expect(policy[:sources][:thinking]).to eq(value: true, source: :provider_override)
      end
    end

    context 'with full precedence chain' do
      it 'resolves each capability from the highest-priority source' do
        policy = described_class.resolve(
          real: { tools: false, vision: true },
          provider_catalog: { structured_output: true },
          probe: { embeddings: true },
          provider_envelope: { streaming: true, tools: true },
          provider_config: { capabilities: { tools: true, vision: false } },
          instance_config: { capabilities: { tools: false } },
          model_config: { capabilities: { tools: true } }
        )

        expect(policy[:capabilities]).to include(:tools, :embedding, :streaming, :structured_output)
        expect(policy[:capabilities]).not_to include(:vision)
        expect(policy[:sources][:tools]).to eq(value: true, source: :model_override)
        expect(policy[:sources][:vision]).to eq(value: false, source: :provider_override)
        expect(policy[:sources][:embedding]).to eq(value: true, source: :probe)
        expect(policy[:sources][:structured_output]).to eq(value: true, source: :provider_catalog)
        expect(policy[:sources][:streaming]).to eq(value: true, source: :provider_envelope)
      end
    end

    context 'with boolean aliases' do
      it 'resolves enable_* and *_flag aliases' do
        policy = described_class.resolve(
          real: {},
          provider_catalog: {},
          probe: {},
          provider_envelope: {},
          provider_config: {},
          instance_config: { enable_thinking: true, streaming_flag: true, tools_flag: false },
          model_config: {}
        )

        expect(policy[:capabilities]).to contain_exactly(:streaming, :thinking)
        expect(policy[:sources][:thinking]).to eq(value: true, source: :instance_override)
        expect(policy[:sources][:streaming]).to eq(value: true, source: :instance_override)
        expect(policy[:sources][:tools]).to eq(value: false, source: :instance_override)
      end

      it 'canonicalizes reasoning, embedding, and image-generation aliases' do
        policy = described_class.resolve(
          real: {},
          provider_catalog: {},
          probe: {},
          provider_envelope: {},
          provider_config: {},
          instance_config: {
            enable_reasoning: true,
            embeddings_flag: true,
            image_generation_flag: true,
            completion_flag: true
          },
          model_config: {}
        )

        expect(policy[:capabilities]).to include(:thinking, :embedding, :image, :completion)
        expect(policy[:sources][:thinking]).to eq(value: true, source: :instance_override)
        expect(policy[:sources][:embedding]).to eq(value: true, source: :instance_override)
        expect(policy[:sources][:image]).to eq(value: true, source: :instance_override)
        expect(policy[:sources][:completion]).to eq(value: true, source: :instance_override)
      end
    end

    context 'when capabilities hash wins over alias at same level' do
      it 'prefers capabilities nested key over boolean alias' do
        policy = described_class.resolve(
          real: {},
          provider_catalog: {},
          probe: {},
          provider_envelope: {},
          provider_config: {},
          instance_config: { capabilities: { tools: true }, tools_flag: false },
          model_config: {}
        )

        expect(policy[:capabilities]).to include(:tools)
        expect(policy[:sources][:tools]).to eq(value: true, source: :instance_override)
      end
    end

    context 'with model override' do
      it 'model override beats instance and provider' do
        policy = described_class.resolve(
          real: {},
          provider_catalog: {},
          probe: {},
          provider_envelope: {},
          provider_config: { capabilities: { thinking: false } },
          instance_config: { capabilities: { thinking: false } },
          model_config: { thinking_flag: true }
        )

        expect(policy[:capabilities]).to include(:thinking)
        expect(policy[:sources][:thinking]).to eq(value: true, source: :model_override)
      end
    end

    context 'with provider envelope' do
      it 'uses provider envelope when no overrides exist' do
        policy = described_class.resolve(
          real: {},
          provider_catalog: {},
          probe: {},
          provider_envelope: { streaming: true },
          provider_config: {},
          instance_config: {},
          model_config: {}
        )

        expect(policy[:capabilities]).to contain_exactly(:streaming)
        expect(policy[:sources][:streaming]).to eq(value: true, source: :provider_envelope)
      end
    end
  end

  describe '.normalized_overrides' do
    it 'handles string keys in capabilities hash' do
      result = described_class.normalized_overrides({ 'capabilities' => { 'streaming' => true } })
      expect(result[:streaming]).to be(true)
    end

    it 'handles symbol keys in capabilities hash' do
      result = described_class.normalized_overrides({ capabilities: { streaming: true } })
      expect(result[:streaming]).to be(true)
    end

    it 'ignores non-boolean values' do
      result = described_class.normalized_overrides({ capabilities: { streaming: 'yes' } })
      expect(result).not_to have_key(:streaming)
    end
  end

  describe '.normalize_hash' do
    it 'returns empty hash for nil' do
      expect(described_class.normalize_hash(nil)).to eq({})
    end

    it 'symbolizes keys' do
      expect(described_class.normalize_hash({ 'foo' => 1 })).to eq({ foo: 1 })
    end
  end
end
