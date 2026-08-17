# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::SettingsCascade do
  let(:llm_conf) do
    {
      vllm: {
        weight: 5,
        model_whitelist: %w[gpt],
        models: {
          'alpha' => { weight: 11, enable_tools: true }
        },
        instances: {
          apollo: {
            weight: 7,
            enable_tools: false,
            models: {
              'alpha' => { weight: 13 },
              'beta' => { enable_tools: true, preferred_min_context_tokens: 100 }
            }
          },
          'string-keyed' => { weight: 9 }
        }
      },
      ollama: {
        instances: { local: {} }
      }
    }
  end

  describe '.resolve_value (pure 3-level cascade, most-specific-first)' do
    let(:provider_conf) { llm_conf[:vllm] }
    let(:instance_conf) { llm_conf[:vllm][:instances][:apollo] }

    it 'resolves the provider leg when no more specific scope carries the key' do
      expect(described_class.resolve_value(provider_conf: provider_conf, instance_cfg: {}, key: :weight)).to eq(5)
    end

    it 'resolves the instance leg over the provider leg' do
      expect(described_class.resolve_value(provider_conf: provider_conf, instance_cfg: instance_conf, key: :weight)).to eq(7)
    end

    it 'resolves the instance-scoped model leg over the provider-scoped model leg' do
      result = described_class.resolve_value(
        provider_conf: provider_conf, instance_cfg: instance_conf, key: :weight, model: 'alpha'
      )
      expect(result).to eq(13) # instance models.alpha (13) beats provider models.alpha (11) and instance weight (7)
    end

    it 'resolves the provider-scoped model leg when the instance model map has no entry' do
      result = described_class.resolve_value(
        provider_conf: provider_conf, instance_cfg: {}, key: :weight, model: 'alpha'
      )
      expect(result).to eq(11)
    end

    it 'resolves the model leg before the instance leg (most-specific-first)' do
      result = described_class.resolve_value(
        provider_conf: provider_conf, instance_cfg: instance_conf, key: :enable_tools, model: 'alpha'
      )
      # provider models.alpha.enable_tools (true) wins over instance enable_tools (false):
      # the model leg is consulted before the instance leg
      expect(result).to be(true)
    end

    it 'skips a model with no model-map entries and falls through to instance/provider' do
      result = described_class.resolve_value(
        provider_conf: provider_conf, instance_cfg: instance_conf, key: :weight, model: 'gamma'
      )
      expect(result).to eq(7)
    end

    it 'returns nil when no scope carries the key' do
      expect(described_class.resolve_value(provider_conf: provider_conf, instance_cfg: instance_conf, key: :missing)).to be_nil
      expect(described_class.resolve_value(provider_conf: {}, instance_cfg: {}, key: :weight)).to be_nil
    end

    context 'with empty values in scopes' do
      it 'skips nil, blank String, and empty Array values, falling through to the next scope' do
        conf = {
          weight: '',
          model_whitelist: [],
          instances: { apollo: { weight: nil, model_whitelist: %w[claude], model_blacklist: [] } }
        }
        # instance nil + provider '' both skip -> nil
        expect(described_class.resolve_value(provider_conf: conf, instance_cfg: conf[:instances][:apollo], key: :weight)).to be_nil
        # instance '' / provider [] : a meaningful instance value resolves, an empty one falls to provider (empty -> nil)
        expect(described_class.resolve_value(provider_conf: {}, instance_cfg: conf[:instances][:apollo], key: :model_whitelist)).to eq(%w[claude])
        expect(described_class.resolve_value(provider_conf: conf, instance_cfg: {}, key: :model_whitelist)).to be_nil
        # instance [] + provider absent -> nil
        expect(described_class.resolve_value(provider_conf: conf, instance_cfg: conf[:instances][:apollo], key: :model_blacklist)).to be_nil
      end

      it 'does NOT skip meaningful non-String values (false, 0)' do
        conf = { enable_thinking: false, weight: 0 }
        expect(described_class.resolve_value(provider_conf: conf, instance_cfg: {}, key: :enable_thinking)).to be(false)
        expect(described_class.resolve_value(provider_conf: conf, instance_cfg: {}, key: :weight)).to eq(0)
      end

      it 'skips empty values in model scopes too' do
        conf = {
          models: { 'alpha' => { weight: '', enable_tools: true } },
          instances: { apollo: { models: { 'alpha' => { enable_tools: false, weight: [] } } } }
        }
        # instance model weight [] skipped, provider model weight '' skipped, no instance/provider weight -> nil
        expect(
          described_class.resolve_value(provider_conf: conf, instance_cfg: conf[:instances][:apollo], key: :weight, model: 'alpha')
        ).to be_nil
        # instance model enable_tools false is meaningful and wins
        expect(
          described_class.resolve_value(provider_conf: conf, instance_cfg: conf[:instances][:apollo], key: :enable_tools, model: 'alpha')
        ).to be(false)
      end
    end

    context 'with String and Symbol key/name variants' do
      it 'accepts String or Symbol keys and instance/model names' do
        expect(described_class.resolve_value(provider_conf: provider_conf, instance_cfg: instance_conf, key: 'weight')).to eq(7)
        expect(described_class.resolve_value(provider_conf: provider_conf, instance_cfg: {}, key: :weight, model: :alpha)).to eq(11)
        expect(
          described_class.resolve_from(llm_conf: llm_conf, provider_family: 'vllm', instance: :apollo, key: :weight)
        ).to eq(7)
      end

      it 'accepts string-keyed settings hashes (YAML/JSON variants)' do
        conf = { 'vllm' => { 'weight' => 3, 'instances' => { 'apollo' => { 'weight' => 4 } } } }
        expect(described_class.resolve_from(llm_conf: conf, provider_family: :vllm, instance: 'apollo', key: :weight)).to eq(4)
      end

      it 'tolerates non-Hash scopes' do
        expect(described_class.resolve_value(provider_conf: nil, instance_cfg: nil, key: :weight)).to be_nil
        expect(described_class.resolve_from(llm_conf: nil, provider_family: :vllm, instance: 'apollo', key: :weight)).to be_nil
      end
    end

    context 'with invalid argument types' do
      it 'rejects non-text keys, instances, models, and provider families' do
        expect { described_class.resolve_value(provider_conf: provider_conf, instance_cfg: {}, key: 5) }
          .to raise_error(ArgumentError, /key must be a String or Symbol/)
        expect { described_class.resolve_value(provider_conf: provider_conf, instance_cfg: {}, key: :weight, model: 5) }
          .to raise_error(ArgumentError, /model must be a String or Symbol/)
        expect { described_class.resolve_from(llm_conf: llm_conf, provider_family: 5, instance: 'a', key: :k) }
          .to raise_error(ArgumentError, /provider_family must be a String or Symbol/)
        expect { described_class.resolve_from(llm_conf: llm_conf, provider_family: :vllm, instance: 5, key: :k) }
          .to raise_error(ArgumentError, /instance must be a String or Symbol/)
      end
    end
  end

  describe '.merge_model_scopes (capability-feeder merge)' do
    it 'merges the provider models.<model> entry with the instance models.<model> entry overriding it' do
      merged = described_class.merge_model_scopes(
        provider_conf: llm_conf[:vllm],
        instance_cfg: llm_conf[:vllm][:instances][:apollo],
        model: 'alpha'
      )
      expect(merged).to eq(weight: 13, enable_tools: true)
    end

    it 'returns {} when no scope carries a models map' do
      expect(described_class.merge_model_scopes(provider_conf: {}, instance_cfg: {}, model: 'alpha')).to eq({})
    end

    it 'ignores non-Hash model entries' do
      conf = { models: { 'alpha' => 'not-a-hash' } }
      expect(described_class.merge_model_scopes(provider_conf: conf, instance_cfg: {}, model: 'alpha')).to eq({})
    end
  end

  describe '.resolve (live Legion::Settings path)' do
    around do |example|
      saved = Legion::Settings.loader.settings[:extensions]
      example.run
    ensure
      if saved.nil?
        Legion::Settings.loader.settings.delete(:extensions)
      else
        Legion::Settings.loader.settings[:extensions] = saved
      end
    end

    it 'reads the real nested extensions.llm.<provider> path, keyed by the config name' do
      Legion::Settings.loader.settings[:extensions] = { llm: llm_conf }

      expect(described_class.resolve(provider_family: :vllm, instance: 'apollo', key: :weight)).to eq(7)
      expect(described_class.resolve(provider_family: :vllm, instance: 'apollo', key: :weight, model: 'alpha')).to eq(13)
      expect(described_class.resolve(provider_family: :vllm, instance: 'nobody', key: :model_whitelist)).to eq(%w[gpt])
      expect(described_class.resolve(provider_family: :vllm, instance: 'nobody', key: :missing)).to be_nil
      expect(described_class.resolve(provider_family: :nope, instance: 'apollo', key: :weight)).to be_nil
    end

    it 'returns nil when no extensions.llm subtree exists at all' do
      Legion::Settings.loader.settings[:extensions] = {}
      expect(described_class.resolve(provider_family: :vllm, instance: 'apollo', key: :weight)).to be_nil
    end
  end

  describe '.resolve_from (frozen subtree, e.g. a router settings snapshot)' do
    it 'resolves the same cascade against a pre-fetched extensions.llm hash' do
      frozen_subtree = llm_conf
      expect(described_class.resolve_from(llm_conf: frozen_subtree, provider_family: :vllm, instance: 'apollo', key: :weight)).to eq(7)
      expect(
        described_class.resolve_from(llm_conf: frozen_subtree, provider_family: :vllm, instance: 'string-keyed', key: :weight)
      ).to eq(9)
    end
  end
end
