# frozen_string_literal: true

# Stub the actor base class before requiring the real actor — the concrete
# Legion::Extensions::Actors::Every lives in LegionIO, which lex-llm does not
# depend on (lex-llm is the lower gem).
unless defined?(Legion::Extensions::Actors::Every)
  module Legion
    module Extensions
      module Actors
        class Every; end # rubocop:disable Lint/EmptyClass
      end
    end
  end
end

$LOADED_FEATURES << 'legion/extensions/actors/every'

require_relative '../../../../../lib/legion/extensions/llm/actors/metering_flush'

RSpec.describe Legion::Extensions::Llm::Actor::MeteringFlush do
  subject(:actor) { described_class.new }

  describe '#runner_class' do
    it 'targets the legion-llm metering module that owns the spool' do
      expect(actor.runner_class).to eq('Legion::LLM::Metering')
    end
  end

  describe '#runner_function' do
    it 'returns flush_spool' do
      expect(actor.runner_function).to eq('flush_spool')
    end
  end

  describe '#time' do
    it 'flushes once per minute' do
      expect(actor.time).to eq(60)
    end
  end

  describe '#run_now?' do
    it 'returns false so it does not fire during boot' do
      expect(actor.run_now?).to be false
    end
  end

  describe '#use_runner?' do
    it 'returns false so it calls the module directly (no AMQP round-trip)' do
      expect(actor.use_runner?).to be false
    end
  end

  describe '#check_subtask?' do
    it 'returns false' do
      expect(actor.check_subtask?).to be false
    end
  end

  describe '#generate_task?' do
    it 'returns false' do
      expect(actor.generate_task?).to be false
    end
  end
end
