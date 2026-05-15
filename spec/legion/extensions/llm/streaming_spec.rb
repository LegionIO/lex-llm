# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Streaming do
  let(:test_obj) do
    Object.new.tap do |obj|
      obj.extend(described_class)
      obj.define_singleton_method(:build_chunk) { |data| "chunk:#{data['x']}" }
    end
  end

  let(:env) { Struct.new(:status).new(200) }

  before do
    stub_const('Faraday::VERSION', '2.0.0')
  end

  it 'skips non-hash SSE payloads' do
    yielded_chunks = []
    handler = test_obj.send(:handle_stream) { |chunk| yielded_chunks << chunk }

    expect { handler.call("data: true\n\n", 0, env) }.not_to raise_error
    expect(yielded_chunks).to eq([])
  end

  it 'processes hash SSE payloads' do
    yielded_chunks = []
    handler = test_obj.send(:handle_stream) { |chunk| yielded_chunks << chunk }

    handler.call("data: {\"x\":\"ok\"}\n\n", 0, env)

    expect(yielded_chunks).to eq(['chunk:ok'])
  end

  describe '#handle_failed_response (private)' do
    let(:error_env) { Struct.new(:status, :body).new(500, nil) }
    let(:non_mutable_env) { Struct.new(:status).new(500) }

    it 'raises ServerError with extracted message when JSON is complete' do
      buffer = +''
      error_chunk = '{"error":{"message":"Model overloaded","code":500}}'
      allow(test_obj).to receive(:handle_parsed_error) do
        raise Legion::Extensions::Llm::ServerError, 'Model overloaded'
      end
      expect { test_obj.send(:handle_failed_response, error_chunk, buffer, error_env) }
        .to raise_error(Legion::Extensions::Llm::ServerError)
    end

    it 'buffers partial JSON on mutable Faraday envs until the error body is complete' do
      buffer = +''
      first_chunk = '{"error":{"message":"The model is currently'
      second_chunk = ' overloaded","code":500}}'
      parsed_error = nil
      allow(test_obj).to receive(:handle_parsed_error) do |data, _env|
        parsed_error = data
        raise Legion::Extensions::Llm::ServerError, 'The model is currently overloaded'
      end

      expect { test_obj.send(:handle_failed_response, first_chunk, buffer, error_env) }.not_to raise_error
      expect(error_env.body).to eq(first_chunk)

      expect { test_obj.send(:handle_failed_response, second_chunk, buffer, error_env) }
        .to raise_error(Legion::Extensions::Llm::ServerError, /overloaded/)
      expect(parsed_error.dig('error', 'message')).to eq('The model is currently overloaded')
      expect(error_env.body).to eq("#{first_chunk}#{second_chunk}")
    end

    it 'raises ServerError with partial message when the env cannot carry the buffered body' do
      buffer = +''
      truncated_chunk = '{"error":{"message":"The model is currently overloaded'
      expect { test_obj.send(:handle_failed_response, truncated_chunk, buffer, non_mutable_env) }
        .to raise_error(Legion::Extensions::Llm::ServerError, /Provider error.*The model is currently overloaded/)
    end

    it 'raises ServerError with generic message when no partial message is extractable and env cannot buffer' do
      buffer = +''
      partial_chunk = '{"error":{'
      expect { test_obj.send(:handle_failed_response, partial_chunk, buffer, non_mutable_env) }
        .to raise_error(Legion::Extensions::Llm::ServerError, /Provider error.*incomplete/)
    end
  end
end
