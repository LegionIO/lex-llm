# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::AutoRegistration do
  # Build a fake provider module that extends AutoRegistration,
  # mimicking what a real lex-llm-* provider would look like.
  let(:fake_provider_class) { Class.new }

  let(:provider_module) do
    klass = fake_provider_class
    mod = Module.new do
      extend Legion::Extensions::Llm::AutoRegistration

      const_set(:PROVIDER_FAMILY, :fake_provider)

      define_singleton_method(:provider_class) { klass }
    end
    mod
  end

  describe '#discover_instances' do
    it 'returns an empty hash by default' do
      expect(provider_module.discover_instances).to eq({})
    end
  end

  describe '#register_discovered_instances' do
    context 'when Call::Registry is not defined' do
      before { hide_const('Legion::LLM::Call::Registry') }

      it 'is a no-op' do
        expect(provider_module.register_discovered_instances).to be_nil
      end
    end

    context 'when Call::Registry is defined' do
      let(:registry) { Module.new { def self.register(*args, **kwargs); end } }
      let(:adapter_class) { Class.new { def initialize(*args, **kwargs); end } }

      before do
        stub_const('Legion::LLM::Call::Registry', registry)
        stub_const('Legion::LLM::Call::LexLLMAdapter', adapter_class)
      end

      it 'calls discover_instances and registers each instance' do
        instances = {
          local: { base_url: 'http://localhost:11434', api_key: 'test' },
          remote: { base_url: 'http://remote:11434', api_key: 'test2' }
        }
        allow(provider_module).to receive(:discover_instances).and_return(instances)
        allow(registry).to receive(:register)

        provider_module.register_discovered_instances

        expect(registry).to have_received(:register).with(
          :fake_provider, an_instance_of(adapter_class), instance: :local,
                                                         metadata: { tier: nil, capabilities: [] }
        )
        expect(registry).to have_received(:register).with(
          :fake_provider, an_instance_of(adapter_class), instance: :remote,
                                                         metadata: { tier: nil, capabilities: [] }
        )
      end

      it 'strips :tier and :capabilities from config before passing to adapter' do
        instances = {
          default: {
            base_url: 'http://localhost:11434',
            api_key: 'sk-test',
            tier: 3,
            capabilities: %i[chat embed]
          }
        }
        allow(provider_module).to receive(:discover_instances).and_return(instances)
        allow(registry).to receive(:register)
        allow(adapter_class).to receive(:new).and_call_original

        provider_module.register_discovered_instances

        expect(adapter_class).to have_received(:new).with(
          :fake_provider,
          fake_provider_class,
          instance_config: { base_url: 'http://localhost:11434', api_key: 'sk-test', instance_id: :default }
        )
      end

      it 'passes the discovered instance id into the adapter config' do
        allow(provider_module).to receive(:discover_instances).and_return(
          local: { base_url: 'http://localhost:11434' },
          west: { base_url: 'http://west:11434' }
        )
        allow(adapter_class).to receive(:new).and_call_original

        provider_module.register_discovered_instances

        expect(adapter_class).to have_received(:new).with(
          :fake_provider,
          fake_provider_class,
          instance_config: { base_url: 'http://localhost:11434', instance_id: :local }
        )
        expect(adapter_class).to have_received(:new).with(
          :fake_provider,
          fake_provider_class,
          instance_config: { base_url: 'http://west:11434', instance_id: :west }
        )
      end

      it 'rescues errors and logs a warning when log is available' do
        allow(provider_module).to receive(:discover_instances).and_raise(RuntimeError, 'boom')

        logger = instance_double(Logger)
        allow(provider_module).to receive(:respond_to?).and_call_original
        allow(provider_module).to receive(:respond_to?).with(:log).and_return(true)
        allow(provider_module).to receive(:log).and_return(logger)
        allow(logger).to receive(:warn)

        provider_module.register_discovered_instances

        expect(logger).to have_received(:warn).with('[fake_provider] self-registration failed: boom')
      end

      it 'rescues errors silently when log is not available' do
        allow(provider_module).to receive(:discover_instances).and_raise(RuntimeError, 'boom')

        expect { provider_module.register_discovered_instances }.not_to raise_error
      end
    end
  end

  describe '#rediscover!' do
    context 'when Call::Registry is not defined' do
      before { hide_const('Legion::LLM::Call::Registry') }

      it 'is a no-op' do
        expect(provider_module.rediscover!).to be_nil
      end
    end

    context 'when Call::Registry is defined' do
      let(:registry) do
        Module.new do
          def self.register(*args, **kwargs); end

          def self.deregister_provider(family); end
        end
      end
      let(:adapter_class) { Class.new { def initialize(*args, **kwargs); end } }

      before do
        stub_const('Legion::LLM::Call::Registry', registry)
        stub_const('Legion::LLM::Call::LexLLMAdapter', adapter_class)
      end

      it 'deregisters the provider and re-runs discovery' do
        instances = { local: { base_url: 'http://localhost:11434' } }
        allow(provider_module).to receive(:discover_instances).and_return(instances)
        allow(registry).to receive(:deregister_provider)
        allow(registry).to receive(:register)

        provider_module.rediscover!

        expect(registry).to have_received(:deregister_provider).with(:fake_provider)
        expect(registry).to have_received(:register).with(
          :fake_provider, an_instance_of(adapter_class), instance: :local,
                                                         metadata: { tier: nil, capabilities: [] }
        )
      end
    end
  end
end
