# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'LLM fleet message envelopes' do
  let(:protocol) { Legion::Extensions::Llm::Fleet::Protocol }
  let(:channel_class) do
    Class.new do
      attr_accessor :default_exchange

      def on_return; end
      def confirm_select(**_kwargs); end
      def wait_for_confirms; end
    end
  end

  def valid_request_options
    {
      routing_key: 'llm.fleet.inference.qwen.ctx8192',
      request_id: 'req-1',
      correlation_id: 'corr-1',
      idempotency_key: 'idem-1',
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
      execution_contract: protocol::EXACT_EXECUTION_CONTRACT,
      offering_id: "off:v1:#{'a' * 64}"
    }
  end

  def valid_response_options
    {
      protocol_version: protocol::VERSION,
      request_id: 'req-1',
      correlation_id: 'corr-1',
      idempotency_key: 'idem-1',
      operation: :chat,
      provider: :vllm,
      provider_instance: :apollo,
      model: 'qwen',
      reply_to: 'llm.fleet.reply.node',
      message_context: { conversation_id: 'conv-1' },
      trace_context: { trace_id: 'trace-1' },
      response: { text: 'hello', stop_reason: :end_turn, usage: { input_tokens: 1, output_tokens: 2 } },
      execution_contract: protocol::EXACT_EXECUTION_CONTRACT,
      offering_id: "off:v1:#{'a' * 64}"
    }
  end

  describe Legion::Extensions::Llm::Fleet::Protocol do
    it 'defines fleet protocol v3 with the one required-field list (P1/E2)' do
      expect(described_class::VERSION).to eq(3)
      expect(described_class::REQUEST_TYPE).to eq('llm.fleet.request')
      expect(described_class::RESPONSE_TYPE).to eq('llm.fleet.response')
      expect(described_class::ERROR_TYPE).to eq('llm.fleet.error')
      expect(described_class::REQUIRED_FIELDS).to include(
        :request_id, :correlation_id, :idempotency_key, :operation, :provider, :provider_instance,
        :model, :params, :reply_to, :message_context, :caller, :trace_context, :signed_token,
        :timeout_seconds, :expires_at, :protocol_version, :execution_contract, :offering_id
      )
      expect(described_class::LEGACY_FIELDS).to eq(%i[schema_version request_type fleet_correlation_id])
    end
  end

  describe Legion::Extensions::Llm::Fleet::FleetEnvelope do
    let(:envelope_class) { described_class }

    it 'wraps a Hash payload and passes an existing envelope through' do
      expect(envelope_class.wrap(a: 1).to_h).to eq(a: 1)
      envelope = envelope_class.new(data: { b: 2 })
      expect(envelope_class.wrap(envelope)).to be(envelope)
    end

    it 'L12: a non-Hash payload is a typed ContractError at the wrap boundary' do
      expect { envelope_class.wrap('not a hash') }
        .to raise_error(Legion::Extensions::Llm::Fleet::ContractError, /expected Hash, got String/)
      expect { envelope_class.wrap(42) }
        .to raise_error(Legion::Extensions::Llm::Fleet::ContractError, /expected Hash, got Integer/)
    end
  end

  describe Legion::Extensions::Llm::Transport::Messages::FleetRequest do
    it 'builds a strict protocol v3 request envelope' do
      message = described_class.new(**valid_request_options)

      expect(message.type).to eq(protocol::REQUEST_TYPE)
      expect(message.routing_key).to eq('llm.fleet.inference.qwen.ctx8192')
      expect(message.reply_to).to eq('llm.fleet.reply.node')
      expect(message.correlation_id).to eq('corr-1')
      expect(message.message).to include(
        protocol_version: 3,
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
        idempotency_key: 'idem-1',
        execution_contract: protocol::EXACT_EXECUTION_CONTRACT,
        offering_id: "off:v1:#{'a' * 64}"
      )
      expect(message.message).not_to include(:schema_version, :request_type, :fleet_correlation_id)
    end

    it 'requires every protocol v3 request field (one Protocol list, E2)' do
      required = protocol::REQUIRED_FIELDS + %i[routing_key]

      required.each do |field|
        expect do
          described_class.new(**valid_request_options.except(field))
        end.to raise_error(ArgumentError, /#{field}/)
      end
    end

    it 'rejects protocol versions other than v3' do
      expect do
        described_class.new(**valid_request_options, protocol_version: 2)
      end.to raise_error(ArgumentError, /protocol_version must be 3/)
    end

    it 'rejects a missing protocol_version (P3 — no default fill)' do
      expect do
        described_class.new(**valid_request_options.except(:protocol_version))
      end.to raise_error(ArgumentError, /protocol_version is required/)
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

    it 'passes confirm_timeout: to confirm_select and calls wait_for_confirms with no args for timeout option' do
      channel = instance_double(channel_class, on_return: nil, wait_for_confirms: true)
      exchange = instance_double(
        Legion::Extensions::Llm::Transport::Exchanges::Fleet,
        publish: true,
        name: 'llm.fleet',
        channel: channel
      )
      message = described_class.new(**valid_request_options)

      allow(channel).to receive(:confirm_select)
      allow(Legion::Extensions::Llm::Transport::Exchanges::Fleet).to receive(:cached_instance).and_return(exchange)
      result = message.publish(publish_confirm_timeout_ms: 5000)

      expect(channel).to have_received(:confirm_select).with(confirm_timeout: 5000)
      expect(channel).to have_received(:wait_for_confirms).with(no_args)
      expect(result).to include(status: :accepted, accepted: true)
    end
  end

  describe Legion::Extensions::Llm::Transport::Messages::FleetResponse do
    it 'builds a protocol v3 correlated response envelope carrying the serialized Canonical::Response (E3)' do
      message = described_class.new(**valid_response_options)

      expect(message.type).to eq(protocol::RESPONSE_TYPE)
      expect(message.routing_key).to eq('llm.fleet.reply.node')
      expect(message.correlation_id).to eq('corr-1')
      expect(message.message).to include(
        protocol_version: 3,
        request_id: 'req-1',
        correlation_id: 'corr-1',
        idempotency_key: 'idem-1',
        operation: :chat,
        reply_to: 'llm.fleet.reply.node',
        provider: :vllm,
        provider_instance: :apollo,
        model: 'qwen',
        response: { text: 'hello', stop_reason: :end_turn, usage: { input_tokens: 1, output_tokens: 2 } },
        execution_contract: protocol::EXACT_EXECUTION_CONTRACT,
        offering_id: "off:v1:#{'a' * 64}"
      )
      expect(message.message).not_to include(:schema_version, :content, :usage, :finish_reason, :tool_calls, :instance)
    end

    it 'requires the response payload and a protocol version' do
      expect do
        described_class.new(**valid_response_options.except(:response))
      end.to raise_error(ArgumentError, /response is required/)
      expect do
        described_class.new(**valid_response_options.except(:protocol_version))
      end.to raise_error(ArgumentError, /protocol_version is required/)
    end

    it 'rejects response protocol versions other than v3' do
      expect do
        described_class.new(**valid_response_options, protocol_version: 2)
      end.to raise_error(ArgumentError, /protocol_version must be 3/)
    end

    it 'is a pass-through for the response payload — the G5 thinking exclusion happens exactly once at the responder builder' do
      message = described_class.new(**valid_response_options, response: { text: 'visible', stop_reason: :end_turn })

      expect(message.message[:response]).to eq(text: 'visible', stop_reason: :end_turn)
      expect(message.message).not_to have_key(:thinking)
      expect(message.encode_message).not_to include('thinking')
    end

    it 'rejects legacy fleet envelope fields' do
      %i[schema_version request_type fleet_correlation_id].each do |field|
        expect do
          described_class.new(**valid_response_options, field => 'legacy')
        end.to raise_error(ArgumentError, /#{field}/)
      end
    end

    it 'publishes replies through the AMQP default exchange without confirms or mandatory routing' do
      default_exchange = instance_double(Bunny::Exchange, publish: true)
      channel = instance_double(Bunny::Channel, default_exchange: default_exchange)
      message = described_class.new(**valid_response_options)

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
      message = described_class.new(**valid_response_options)

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
      message = described_class.new(**valid_response_options)

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
    it 'builds a protocol v3 correlated error envelope (E6)' do
      message = described_class.new(
        **valid_response_options.slice(:protocol_version, :request_id, :correlation_id, :idempotency_key, :operation,
                                       :provider, :provider_instance, :model, :reply_to, :message_context,
                                       :trace_context, :execution_contract, :offering_id),
        code: 'provider_failed',
        message: 'provider failed',
        retryable: true
      )

      expect(message.type).to eq(protocol::ERROR_TYPE)
      expect(message.routing_key).to eq('llm.fleet.reply.node')
      expect(message.message).to include(
        protocol_version: 3,
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
        execution_contract: protocol::EXACT_EXECUTION_CONTRACT,
        offering_id: "off:v1:#{'a' * 64}"
      )
      expect(message.message).not_to include(:schema_version, :instance)
    end

    it 'rejects error protocol versions other than v3 and missing versions' do
      base = valid_response_options.slice(:request_id, :correlation_id, :reply_to)
      expect do
        described_class.new(**base, protocol_version: 2, code: 'provider_failed', message: 'provider failed')
      end.to raise_error(ArgumentError, /protocol_version must be 3/)
      expect do
        described_class.new(**base, code: 'provider_failed', message: 'provider failed')
      end.to raise_error(ArgumentError, /protocol_version is required/)
    end

    it 'publishes errors through the AMQP default exchange without confirms or mandatory routing' do
      default_exchange = instance_double(Bunny::Exchange, publish: true)
      channel = instance_double(Bunny::Channel, default_exchange: default_exchange)
      message = described_class.new(**valid_response_options.slice(:protocol_version, :request_id, :correlation_id,
                                                                   :reply_to),
                                    code: 'provider_failed', message: 'provider failed')

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
      message = described_class.new(**valid_response_options.slice(:protocol_version, :request_id, :correlation_id,
                                                                   :reply_to),
                                    code: 'provider_failed', message: 'provider failed')

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
