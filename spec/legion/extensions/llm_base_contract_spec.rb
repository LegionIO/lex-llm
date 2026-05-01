# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm do
  include_context 'with fake llm provider'

  before do
    stub_const(
      'SpecSupport::EchoTool',
      Class.new(Legion::Extensions::Llm::Tool) do
        description 'Echo a numeric value'
        param :value, type: :integer, desc: 'Value to echo'

        def execute(value:)
          "echo #{value}"
        end
      end
    )
  end

  it 'loads and discovers provider classes from the namespace' do
    provider_classes = Legion::Extensions::Llm::Models.scan_provider_classes
    expect(provider_classes).to include(fake_llm: SpecSupport::FakeLLMProvider)
    expect(Legion::Extensions::Llm::Routing::ModelOffering).to be_a(Class)
  end

  it 'lets a provider gem register options and satisfy chat through the shared API' do
    chat = described_class.chat(model: 'fake-chat-model', provider: :fake_llm, assume_model_exists: true)
    response = chat.ask('hello')

    expect(response).to have_attributes(
      role: :assistant,
      content: 'fake response to hello',
      model_id: 'fake-chat-model',
      input_tokens: 10,
      output_tokens: 5
    )
  end

  it 'runs shared tool orchestration without provider-specific payload code' do
    response = described_class.chat(model: 'fake-chat-model', provider: :fake_llm, assume_model_exists: true)
                              .with_tool(SpecSupport::EchoTool)
                              .ask('use the tool')

    expect(response.content).to eq('tool result: echo 21')
  end

  it 'normalizes schema responses through the base chat layer' do
    schema = {
      name: 'answer',
      schema: {
        type: 'object',
        properties: { answer: { type: 'integer' } },
        required: ['answer']
      }
    }

    response = described_class.chat(model: 'fake-chat-model', provider: :fake_llm, assume_model_exists: true)
                              .with_schema(schema)
                              .ask('structured')

    expect(response.content).to eq({ 'answer' => 42 })
  end

  it 'delegates embedding, moderation, image, and transcription calls through registered providers' do
    expect(described_class.embed('hello', model: 'fake-embed', provider: :fake_llm, assume_model_exists: true).vectors)
      .to eq([0.5, 0.5, 0.5])

    expect(described_class.moderate('safe', model: 'fake-moderation', provider: :fake_llm, assume_model_exists: true))
      .not_to be_flagged

    expect(described_class.paint('draw', model: 'fake-image', provider: :fake_llm, assume_model_exists: true).to_blob)
      .to eq('fake-image')

    expect(described_class.transcribe('audio.wav', model: 'fake-audio', provider: :fake_llm,
                                                   assume_model_exists: true).text)
      .to eq('fake transcript')
  end

  it 'connects model offerings to Legion fleet queue construction end to end' do
    offering = Legion::Extensions::Llm::Routing::ModelOffering.new(
      provider_family: :fake_llm,
      instance_id: :worker_one,
      transport: :rabbitmq,
      model: 'fake-chat-model',
      limits: { context_window: 16_384 }
    )
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

    queue_class = Legion::Extensions::Llm::Transport::FleetLane.build_queue_class(
      queue_name: offering.lane_key,
      exchange_class: exchange_class,
      base_queue_class: base_queue
    )

    expect(queue_class.new.queue_name).to eq('llm.fleet.inference.fake-chat-model.ctx16384')
  end
end
