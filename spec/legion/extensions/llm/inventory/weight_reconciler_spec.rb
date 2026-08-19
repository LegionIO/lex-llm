# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'legion/extensions/llm/inventory/records'
require_relative '../../../../support/ssot_registry_helpers'

RSpec.describe 'Inventory::WeightReconciler' do
  include SsotRegistryHelpers

  inventory = Legion::Extensions::Llm::Inventory

  let(:reconciler) { inventory.const_get(:WeightReconciler) }
  let(:tracker_class) { inventory.const_get(:DormantWeightTracker) }
  let(:key) { instance_key(family: 'vllm', instance: 'helios') }
  let(:mutex) { Mutex.new }
  let(:identity_draft) { drafts.first }

  it 'loads its Set dependency when directly required without the ambient constant' do
    script = <<~RUBY
      require 'tmpdir'

      Object.send(:remove_const, :Set)
      $LOADED_FEATURES.delete_if { |path| File.basename(path) == 'set.rb' }
      Dir.mktmpdir do |directory|
        File.write(File.join(directory, 'set.rb'), <<~'SET')
          class Set
            def initialize(values = []) = @values = values.to_a.uniq
            def difference(other) = self.class.new(@values.reject { |value| other.include?(value) })
            def sort_by(&block) = @values.sort_by(&block)
            def replace(other) = (@values = other.to_a; self)
            def include?(value) = @values.include?(value)
            def to_a = @values.dup
          end
        SET
        $LOAD_PATH.unshift(directory)
        require 'legion/extensions/llm/inventory/weight_reconciler'
        tracker = Legion::Extensions::Llm::Inventory::DormantWeightTracker.new
        abort 'wrong result' unless tracker.observe(configured_keys: [[:vllm]], published_keys: []).size == 1
      end
    RUBY

    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, '-Ilib', '-e', script,
      chdir: File.expand_path('../../../../..', __dir__)
    )

    expect(status.success?).to be(true), stderr
  end

  def settings_for(provider: {}, tier: 100)
    {
      extensions: { llm: { vllm: provider } },
      llm: { routing: { tier_weights: { local: tier } } }
    }
  end

  def state_for(draft: identity_draft, published: true, sequence: 0)
    {
      instance_key: key, offerings: [draft].freeze, published: published,
      sequence: sequence, publisher_token: 'ptok:v1:test'
    }
  end

  it 'rebuilds every offering with the current weight pair in a frozen array' do
    rebuilt = reconciler.rebuild_offerings(
      settings: settings_for(provider: { weight: 110 }), instance_key: key,
      offerings: [identity_draft]
    )

    expect(rebuilt).to be_frozen
    expect(rebuilt.first.weight_inputs)
      .to eq(tier: 100, provider: 110, instance: 100, model_or_offering: 100)
    expect(rebuilt.first.base_weight).to eq(110_000_000)
    expect(rebuilt.first).to eq(
      identity_draft.with(
        weight_inputs: { tier: 100, provider: 110, instance: 100, model_or_offering: 100 },
        base_weight: 110_000_000
      )
    )
  end

  it 'returns false and publishes nothing when the rebuilt offerings are equivalent' do
    state = state_for
    replace = instance_spy(Proc)

    result = reconciler.commit_if_changed!(
      settings: settings_for, instance_id: 'helios', state: state,
      discovered_offerings: [identity_draft], mutex: mutex,
      equivalent: ->(previous, current) { previous == current }, replace: replace
    )

    expect(result).to be(false)
    expect(replace).not_to have_received(:call)
    expect(state).to include(sequence: 0, offerings: [identity_draft])
  end

  it 'publishes a changed frozen array then atomically updates sequence, cache, and signature' do
    state = state_for
    published = []
    signature = ->(offerings) { offerings.map { |draft| [draft.base_weight, draft.model] } }
    replace = lambda do |instance_id:, state:, offerings:, sequence:|
      published << { instance_id: instance_id, state: state, offerings: offerings, sequence: sequence }
    end

    result = reconciler.commit_if_changed!(
      settings: settings_for(provider: { weight: 110 }), instance_id: 'helios', state: state,
      discovered_offerings: [identity_draft], mutex: mutex,
      equivalent: ->(previous, current) { previous == current }, replace: replace,
      stable_signature: signature
    )

    expect(result).to be(true)
    expect(published.one?).to be(true)
    expect(published.first).to include(instance_id: 'helios', state: state, sequence: 1)
    expect(published.first[:offerings]).to be_frozen
    expect(published.first[:offerings]).to be_a(Array)
    expect(state[:sequence]).to eq(1)
    expect(state[:offerings]).to equal(published.first[:offerings])
    expect(state[:signature]).to eq([[110_000_000, 'gemma4']])
  end

  it 'updates an unpublished cache without replacing or advancing its sequence' do
    state = state_for(published: false)
    replace = instance_spy(Proc)

    result = reconciler.commit_if_changed!(
      settings: settings_for(provider: { weight: 110 }), instance_id: 'helios', state: state,
      discovered_offerings: [identity_draft], mutex: mutex,
      equivalent: ->(previous, current) { previous == current }, replace: replace
    )

    expect(result).to be(true)
    expect(replace).not_to have_received(:call)
    expect(state[:sequence]).to eq(0)
    expect(state[:offerings].first.base_weight).to eq(110_000_000)
  end

  it 'leaves published state unchanged when replacement raises so the next pass can retry' do
    state = state_for
    before = state.dup
    replace = ->(**) { raise 'publisher down' }

    expect do
      reconciler.commit_if_changed!(
        settings: settings_for(provider: { weight: 110 }), instance_id: 'helios', state: state,
        discovered_offerings: [identity_draft], mutex: mutex,
        equivalent: ->(previous, current) { previous == current }, replace: replace
      )
    end.to raise_error(RuntimeError, 'publisher down')
    expect(state).to eq(before)
  end

  it 'tracks initializing state and activates it only while the same object remains tracked' do
    states = {}
    state = state_for(published: true)
    reconciler.track_initializing!(states: states, state_key: 'helios', state: state, mutex: mutex)
    expect(state[:published]).to be(false)
    expect(states['helios']).to equal(state)

    activations = []
    activated = reconciler.activate_tracked!(
      settings: settings_for(provider: { weight: 120 }), instance_id: 'helios',
      state_key: 'helios', state: state, states: states, mutex: mutex,
      probe_token: :probe, activation_sequence: ->(tracked) { tracked.fetch(:sequence) },
      activate: ->(**kwargs) { activations << kwargs }
    )
    expect(activated).to be(true)
    expect(activations.first[:offerings].first.base_weight).to eq(120_000_000)
    expect(state[:offerings]).to equal(activations.first[:offerings])
    expect(state[:published]).to be(true)

    states.delete('helios')
    expect(
      reconciler.activate_tracked!(
        settings: settings_for, instance_id: 'helios', state_key: 'helios', state: state,
        states: states, mutex: mutex, probe_token: :probe,
        activation_sequence: ->(tracked) { tracked.fetch(:sequence) }, activate: ->(**) { raise 'not called' }
      )
    ).to be(false)
  end

  it 'leaves initializing state unchanged when activation publication raises' do
    state = state_for(published: false)
    states = { 'helios' => state }
    before = state.dup

    expect do
      reconciler.activate_tracked!(
        settings: settings_for(provider: { weight: 120 }), instance_id: 'helios',
        state_key: 'helios', state: state, states: states, mutex: mutex,
        probe_token: :probe, activation_sequence: ->(tracked) { tracked.fetch(:sequence) + 1 },
        activate: ->(**) { raise 'activation down' }
      )
    end.to raise_error(RuntimeError, 'activation down')
    expect(state).to eq(before)
  end

  it 'logs each dormant key once, clears it on appearance, and logs re-disappearance' do
    tracker = tracker_class.new
    model_settings = settings_for(provider: { models: { ghost: { weight: 125 } } })
    states = { 'helios' => state_for }
    logged = []
    observe = lambda do
      reconciler.observe_dormant!(
        settings: model_settings, provider_family: :vllm, states: states,
        mutex: mutex, tracker: tracker, dormant_logger: ->(key_value) { logged << key_value }
      )
    end

    observe.call
    observe.call
    expect(logged).to eq([[:vllm, :model, 'ghost']])

    states['helios'] = state_for(draft: drafts(model: 'ghost', native: 'ghost').first)
    observe.call
    states['helios'] = state_for
    observe.call
    expect(logged).to eq([[:vllm, :model, 'ghost'], [:vllm, :model, 'ghost']])

    tracker.clear!
    observe.call
    expect(logged.size).to eq(3)
  end

  it 'does not let an unpublished state satisfy a configured key and rejects malformed scopes' do
    tracker = tracker_class.new
    logged = []
    states = { 'helios' => state_for(published: false) }
    settings = settings_for(provider: { models: { gemma4: { weight: 125 } } })
    reconciler.observe_dormant!(
      settings: settings, provider_family: :vllm, states: states, mutex: mutex,
      tracker: tracker, dormant_logger: ->(value) { logged << value }
    )
    expect(logged).to include([:vllm, :model, 'gemma4'])

    expect do
      reconciler.observe_dormant!(
        settings: settings_for(provider: { models: false }), provider_family: :vllm,
        states: {}, mutex: mutex, tracker: tracker, dormant_logger: ->(_value) {}
      )
    end.to raise_error(ArgumentError, /weight configuration scope must be a Hash/)
  end

  it 'uses the exact provider, instance, model, instance-model, and offering dormant keys' do
    offering_id = inventory::Identity.offering_id(instance_key: key, provider_native_key: 'gemma4')
    settings = settings_for(
      provider: {
        weight: false,
        models: { gemma4: { weight: 101 } },
        instances: { helios: { weight: 0, models: { gemma4: { weight: 102 } } } },
        offerings: { offering_id => { weight: 103 } }
      },
      tier: 777
    )
    tracker = tracker_class.new
    logged = []

    reconciler.observe_dormant!(
      settings: settings, provider_family: :vllm, states: {}, mutex: mutex,
      tracker: tracker, dormant_logger: ->(value) { logged << value }
    )
    expect(logged).to contain_exactly(
      %i[vllm provider],
      [:vllm, :instance, 'helios'],
      [:vllm, :model, 'gemma4'],
      [:vllm, :instance, 'helios', :model, 'gemma4'],
      [:vllm, :offering, offering_id]
    )
    expect(logged.flatten).not_to include(:tier)

    reconciler.observe_dormant!(
      settings: settings, provider_family: :vllm,
      states: { 'helios' => state_for }, mutex: mutex,
      tracker: tracker, dormant_logger: ->(value) { logged << value }
    )
    expect(logged.size).to eq(5)
  end

  it 'serializes concurrent ordinary commits and leaves cache equal to the final publication' do
    state = state_for
    publications = []
    ready = Queue.new
    start = Queue.new
    replace = lambda do |offerings:, sequence:, **|
      publications << [sequence, offerings]
    end
    run = lambda do |weight|
      ready << true
      start.pop
      reconciler.commit_if_changed!(
        settings: settings_for(provider: { weight: weight }), instance_id: 'helios', state: state,
        discovered_offerings: [identity_draft], mutex: mutex,
        equivalent: ->(previous, current) { previous == current }, replace: replace
      )
    end
    threads = [Thread.new { run.call(110) }, Thread.new { run.call(120) }]
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:join)

    expect(publications.map(&:first)).to eq([1, 2])
    expect(state[:sequence]).to eq(2)
    expect(state[:offerings]).to equal(publications.last.last)
    expect(state[:offerings].first.weight_inputs).to eq(publications.last.last.first.weight_inputs)
  end
end
