# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'LLM fleet message envelopes' do
  let(:protocol) { Legion::Extensions::Llm::Fleet::Protocol }
  let(:channel_class) do
    Class.new do
      attr_accessor :default_exchange

      def on_return; end
      def confirm_select; end
      def wait_for_confirms(_timeout = nil); end
    end
  end

  def valid_request_options
    {
      routing_key: 'llm.fleet.inference.qwen.ctx8192',
      request_id: 'req-1',
      correlation_id: 'corr-1',
      operation: :chat,
      provider: :vllm,
      provider_instance: :apollo,
      model: 'qwen',
      params: { messages: [{ role: 'user', content: 'hello' }] },
      reply_to: 'llm.fleet.reply.node',
      message_context: { conversation_id: 'conv-1' },
      caller: { service: 'legion-llm' },
      trace_context: { trace_id: 'trace-1' },
      signed_token: 'signed.jwt',
      timeout_seconds: 30,
      expires_at: '2026-05-06T12:00:30Z',
      protocol_version: protocol::VERSION,
      idempotency_key: 'idem-1'
    }
  end

  describe Legion::Extensions::Llm::Fleet::Protocol do
    it 'defines fleet protocol v2 message types' do
      expect(described_class::VERSION).to eq(2)
      expect(described_class::REQUEST_TYPE).to eq('llm.fleet.request')
      expect(described_class::RESPONSE_TYPE).to eq('llm.fleet.response')
      expect(described_class::ERROR_TYPE).to eq('llm.fleet.error')
    end
  end

  describe Legion::Extensions::Llm::Transport::Messages::FleetRequest do
    it 'builds a strict protocol v2 request envelope' do
      message = described_class.new(**valid_request_options)

      expect(message.type).to eq(protocol::REQUEST_TYPE)
      expect(message.routing_key).to eq('llm.fleet.inference.qwen.ctx8192')
      expect(message.reply_to).to eq('llm.fleet.reply.node')
      expect(message.correlation_id).to eq('corr-1')
      expect(message.message).to include(
        protocol_version: 2,
        request_id: 'req-1',
        correlation_id: 'corr-1',
        operation: :chat,
        provider: :vllm,
        provider_instance: :apollo,
        model: 'qwen',
        params: { messages: [{ role: 'user', content: 'hello' }] },
        reply_to: 'llm.fleet.reply.node',
        message_context: { conversation_id: 'conv-1' },
        caller: { service: 'legion-llm' },
        trace_context: { trace_id: 'trace-1' },
        signed_token: 'signed.jwt',
        timeout_seconds: 30,
        expires_at: '2026-05-06T12:00:30Z',
        idempotency_key: 'idem-1'
      )
      expect(message.message).not_to include(:schema_version, :request_type, :fleet_correlation_id)
    end

    it 'requires every protocol v2 request field' do
      required = %i[
        request_id correlation_id operation provider provider_instance model params reply_to
        message_context caller trace_context signed_token timeout_seconds expires_at protocol_version idempotency_key
      ]

      required.each do |field|
        expect do
          described_class.new(**valid_request_options.except(field))
        end.to raise_error(ArgumentError, /#{field}/)
      end
    end

    it 'rejects protocol versions other than v2' do
      expect do
        described_class.new(**valid_request_options, protocol_version: 1)
      end.to raise_error(ArgumentError, /protocol_version/)
    end

    it 'rejects legacy fleet envelope fields' do
      %i[schema_version request_type fleet_correlation_id].each do |field|
        expect do
          described_class.new(**valid_request_options, field => 'legacy')
        end.to raise_error(ArgumentError, /#{field}/)
        expect do
          described_class.new(**valid_request_options, field.to_s => 'legacy')
        end.to raise_error(ArgumentError, /#{field}/)
      end
    end

    it 'publishes requests with mandatory routing, publisher confirms, no spool, and an accepted result by default' do
      channel = instance_double(channel_class, on_return: nil, confirm_select: nil, wait_for_confirms: true)
      exchange = instance_double(
        Legion::Extensions::Llm::Transport::Exchanges::Fleet,
        publish: true,
        name: 'llm.fleet',
        channel: channel
      )
      message = described_class.new(**valid_request_options)

      allow(Legion::Extensions::Llm::Transport::Exchanges::Fleet).to receive(:cached_instance).and_return(exchange)
      result = message.publish

      expect(exchange).to have_received(:publish).with(
        kind_of(String),
        hash_including(
          routing_key: 'llm.fleet.inference.qwen.ctx8192',
          mandatory: true,
          correlation_id: 'corr-1',
          type: protocol::REQUEST_TYPE
        )
      )
      expect(channel).to have_received(:on_return)
      expect(channel).to have_received(:confirm_select)
      expect(channel).to have_received(:wait_for_confirms)
      expect(result).to include(status: :accepted, accepted: true, exchange: 'llm.fleet')
    end
  end

  describe Legion::Extensions::Llm::Transport::Messages::FleetResponse do
    it 'builds a protocol v2 correlated response envelope' do
      message = described_class.new(
        request_id: 'req-1',
        correlation_id: 'corr-1',
        idempotency_key: 'idem-1',
        operation: :chat,
        reply_to: 'llm.fleet.reply.node',
        provider: :vllm,
        provider_instance: :apollo,
        model: 'qwen',
        content: 'hello',
        message_context: { conversation_id: 'conv-1' },
        trace_context: { trace_id: 'trace-1' }
      )

      expect(message.type).to eq(protocol::RESPONSE_TYPE)
      expect(message.routing_key).to eq('llm.fleet.reply.node')
      expect(message.correlation_id).to eq('corr-1')
      expect(message.message).to include(
        protocol_version: 2,
        request_id: 'req-1',
        correlation_id: 'corr-1',
        idempotency_key: 'idem-1',
        operation: :chat,
        reply_to: 'llm.fleet.reply.node',
        provider: :vllm,
        provider_instance: :apollo,
        model: 'qwen',
        content: 'hello',
        message_context: { conversation_id: 'conv-1' },
        trace_context: { trace_id: 'trace-1' }
      )
      expect(message.message).not_to include(:schema_version)
    end

    it 'rejects response protocol versions other than v2' do
      expect do
        described_class.new(
          request_id: 'req-1',
          correlation_id: 'corr-1',
          reply_to: 'llm.fleet.reply.node',
          content: 'hello',
          protocol_version: 1
        )
      end.to raise_error(ArgumentError, /protocol_version/)
    end

    it 'does not expose thinking in caller-visible response payloads' do
      message = described_class.new(
        request_id: 'req-1',
        correlation_id: 'corr-1',
        reply_to: 'llm.fleet.reply.node',
        content: 'visible',
        thinking: 'hidden'
      )

      expect(message.message).to include(content: 'visible')
      expect(message.message).not_to have_key(:thinking)
      expect(message.encode_message).not_to include('hidden', 'thinking')
    end

    it 'publishes replies through the AMQP default exchange without confirms or mandatory routing' do
      default_exchange = instance_double(Bunny::Exchange, publish: true)
      channel = instance_double(Bunny::Channel, default_exchange: default_exchange)
      message = described_class.new(
        request_id: 'req-1',
        correlation_id: 'corr-1',
        reply_to: 'llm.fleet.reply.node',
        content: 'hello'
      )

      allow(message).to receive(:channel).and_return(channel)
      message.publish

      expect(default_exchange).to have_received(:publish).with(
        kind_of(String),
        hash_including(
          routing_key: 'llm.fleet.reply.node',
          mandatory: false,
          correlation_id: 'corr-1',
          type: protocol::RESPONSE_TYPE
        )
      )
    end

    it 'accepts standard transport publish options and returns accepted reply results' do
      channel = instance_double(channel_class, default_exchange: nil, on_return: nil)
      default_exchange = instance_double(Bunny::Exchange, publish: true, name: 'default', channel: channel)
      allow(channel).to receive(:default_exchange).and_return(default_exchange)
      message = described_class.new(
        request_id: 'req-1',
        correlation_id: 'corr-1',
        reply_to: 'llm.fleet.reply.node',
        content: 'hello'
      )

      allow(message).to receive(:channel).and_return(channel)
      result = message.publish(return_result: true, headers: { 'x-custom' => 'yes' }, mandatory: true)

      expect(default_exchange).to have_received(:publish).with(
        kind_of(String),
        hash_including(
          routing_key: 'llm.fleet.reply.node',
          mandatory: true,
          headers: hash_including('x-custom' => 'yes')
        )
      )
      expect(result).to include(
        status: :accepted,
        accepted: true,
        exchange: 'default',
        routing_key: 'llm.fleet.reply.node',
        correlation_id: 'corr-1'
      )
    end

    it 'returns a transport-style failure result for transient reply publish errors' do
      default_exchange = instance_double(Bunny::Exchange, name: 'default')
      channel = instance_double(Bunny::Channel, default_exchange: default_exchange)
      message = described_class.new(
        request_id: 'req-1',
        correlation_id: 'corr-1',
        reply_to: 'llm.fleet.reply.node',
        content: 'hello'
      )

      allow(default_exchange).to receive(:publish).and_raise(IOError, 'socket closed')
      allow(message).to receive(:channel).and_return(channel)
      allow(message).to receive(:handle_exception)
      result = message.publish(spool: false)

      expect(result).to include(
        status: :failed,
        accepted: false,
        error_class: 'IOError',
        routing_key: 'llm.fleet.reply.node',
        correlation_id: 'corr-1'
      )
    end
  end

  describe Legion::Extensions::Llm::Transport::Messages::FleetError do
    it 'builds a protocol v2 correlated error envelope' do
      message = described_class.new(
        request_id: 'req-1',
        correlation_id: 'corr-1',
        idempotency_key: 'idem-1',
        operation: :chat,
        reply_to: 'llm.fleet.reply.node',
        provider: :vllm,
        provider_instance: :apollo,
        model: 'qwen',
        code: 'provider_failed',
        message: 'provider failed',
        retryable: true,
        message_context: { conversation_id: 'conv-1' },
        trace_context: { trace_id: 'trace-1' }
      )

      expect(message.type).to eq(protocol::ERROR_TYPE)
      expect(message.routing_key).to eq('llm.fleet.reply.node')
      expect(message.message).to include(
        protocol_version: 2,
        request_id: 'req-1',
        correlation_id: 'corr-1',
        idempotency_key: 'idem-1',
        operation: :chat,
        reply_to: 'llm.fleet.reply.node',
        provider: :vllm,
        provider_instance: :apollo,
        model: 'qwen',
        code: 'provider_failed',
        message: 'provider failed',
        retryable: true,
        message_context: { conversation_id: 'conv-1' },
        trace_context: { trace_id: 'trace-1' }
      )
      expect(message.message).not_to include(:schema_version)
    end

    it 'rejects error protocol versions other than v2' do
      expect do
        described_class.new(
          request_id: 'req-1',
          correlation_id: 'corr-1',
          reply_to: 'llm.fleet.reply.node',
          code: 'provider_failed',
          message: 'provider failed',
          protocol_version: 1
        )
      end.to raise_error(ArgumentError, /protocol_version/)
    end

    it 'publishes errors through the AMQP default exchange without confirms or mandatory routing' do
      default_exchange = instance_double(Bunny::Exchange, publish: true)
      channel = instance_double(Bunny::Channel, default_exchange: default_exchange)
      message = described_class.new(
        request_id: 'req-1',
        correlation_id: 'corr-1',
        reply_to: 'llm.fleet.reply.node',
        code: 'provider_failed',
        message: 'provider failed'
      )

      allow(message).to receive(:channel).and_return(channel)
      message.publish

      expect(default_exchange).to have_received(:publish).with(
        kind_of(String),
        hash_including(
          routing_key: 'llm.fleet.reply.node',
          mandatory: false,
          correlation_id: 'corr-1',
          type: protocol::ERROR_TYPE
        )
      )
    end

    it 'accepts standard transport publish options when publishing errors' do
      channel = instance_double(channel_class, default_exchange: nil, on_return: nil)
      default_exchange = instance_double(Bunny::Exchange, publish: true, name: 'default', channel: channel)
      allow(channel).to receive(:default_exchange).and_return(default_exchange)
      message = described_class.new(
        request_id: 'req-1',
        correlation_id: 'corr-1',
        reply_to: 'llm.fleet.reply.node',
        code: 'provider_failed',
        message: 'provider failed'
      )

      allow(message).to receive(:channel).and_return(channel)
      result = message.publish(return_result: true, headers: { 'x-custom' => 'yes' }, mandatory: true)

      expect(default_exchange).to have_received(:publish).with(
        kind_of(String),
        hash_including(
          routing_key: 'llm.fleet.reply.node',
          mandatory: true,
          headers: hash_including('x-custom' => 'yes')
        )
      )
      expect(result).to include(status: :accepted, accepted: true, exchange: 'default')
    end
  end
end
# rubocop:enable RSpec/DescribeClass
