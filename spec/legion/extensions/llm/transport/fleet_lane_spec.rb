# frozen_string_literal: true

require 'lex_llm'

RSpec.describe Legion::Extensions::Llm::Transport::FleetLane do
  describe '.queue_options' do
    it 'returns durable quorum live-work queue defaults' do
      options = described_class.queue_options

      expect(options[:durable]).to be(true)
      expect(options[:auto_delete]).to be(false)
      expect(options[:arguments]).to include(
        'x-queue-type' => 'quorum',
        'x-queue-leader-locator' => 'balanced',
        'x-overflow' => 'reject-publish',
        'x-expires' => 60_000,
        'x-message-ttl' => 120_000,
        'x-max-length' => 100,
        'x-delivery-limit' => 3,
        'x-consumer-timeout' => 300_000
      )
    end

    it 'allows provider gems to override lane limits' do
      options = described_class.queue_options(queue_max_length: 25, delivery_limit: 7)

      expect(options[:arguments]['x-max-length']).to eq(25)
      expect(options[:arguments]['x-delivery-limit']).to eq(7)
    end
  end

  describe '.build_queue_class' do
    it 'builds a queue class without requiring legion-transport at gem load time' do
      exchange_class = Class.new
      base_queue = Class.new do
        attr_reader :bindings

        def initialize
          @bindings = []
        end

        def bind(exchange, routing_key:)
          @bindings << [exchange, routing_key]
        end
      end

      queue_class = described_class.build_queue_class(
        queue_name: 'llm.fleet.embed.nomic-embed-text',
        exchange_class: exchange_class,
        base_queue_class: base_queue
      )
      queue = queue_class.new

      expect(queue.queue_name).to eq('llm.fleet.embed.nomic-embed-text')
      expect(queue.queue_options[:arguments]['x-queue-type']).to eq('quorum')
      expect(queue.dlx_enabled).to be(false)
      expect(queue.bindings.first.last).to eq('llm.fleet.embed.nomic-embed-text')
    end
  end
end
