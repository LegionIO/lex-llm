# frozen_string_literal: true

require 'base64'
require 'digest/sha1'
require 'event_stream_parser'
require 'faraday'
require 'faraday/multipart'
require 'faraday/retry'
require 'json'
require 'logger'
require 'marcel'
require 'securerandom'
require 'date'
require 'time'
require 'ruby_llm/schema'
require 'zeitwerk'

# Shared LegionIO LLM provider framework.
module LexLLM
  loader = Zeitwerk::Loader.for_gem
  loader.inflector.inflect(
    'azure' => 'Azure',
    'UI' => 'UI',
    'api' => 'API',
    'bedrock' => 'Bedrock',
    'deepseek' => 'DeepSeek',
    'gpustack' => 'GPUStack',
    'llm' => 'LLM',
    'mistral' => 'Mistral',
    'openai' => 'OpenAI',
    'openrouter' => 'OpenRouter',
    'pdf' => 'PDF',
    'perplexity' => 'Perplexity',
    'lex_llm' => 'LexLLM',
    'vertexai' => 'VertexAI',
    'xai' => 'XAI'
  )
  loader.ignore("#{__dir__}/tasks")
  loader.ignore("#{__dir__}/generators")
  loader.ignore("#{__dir__}/lex_llm.rb")
  loader.ignore("#{__dir__}/legion")
  loader.ignore("#{__dir__}/lex_llm/railtie.rb")
  loader.setup

  Schema = ::RubyLLM::Schema unless const_defined?(:Schema, false)

  class Error < StandardError; end

  class << self
    def context
      context_config = config.dup
      yield context_config if block_given?
      Context.new(context_config)
    end

    def chat(...)
      Chat.new(...)
    end

    def embed(...)
      Embedding.embed(...)
    end

    def moderate(...)
      Moderation.moderate(...)
    end

    def paint(...)
      Image.paint(...)
    end

    def transcribe(...)
      Transcription.transcribe(...)
    end

    def models
      Models.instance
    end

    def providers
      Provider.providers.values
    end

    def configure
      yield config
    end

    def config
      @config ||= Configuration.new
    end

    def logger
      @logger ||= config.logger || Logger.new(
        config.log_file,
        progname: 'LexLLM',
        level: config.log_level
      )
    end
  end
end

LexLLM::Provider.register :anthropic, LexLLM::Providers::Anthropic
LexLLM::Provider.register :azure, LexLLM::Providers::Azure
LexLLM::Provider.register :bedrock, LexLLM::Providers::Bedrock
LexLLM::Provider.register :deepseek, LexLLM::Providers::DeepSeek
LexLLM::Provider.register :gemini, LexLLM::Providers::Gemini
LexLLM::Provider.register :gpustack, LexLLM::Providers::GPUStack
LexLLM::Provider.register :mistral, LexLLM::Providers::Mistral
LexLLM::Provider.register :ollama, LexLLM::Providers::Ollama
LexLLM::Provider.register :openai, LexLLM::Providers::OpenAI
LexLLM::Provider.register :openrouter, LexLLM::Providers::OpenRouter
LexLLM::Provider.register :perplexity, LexLLM::Providers::Perplexity
LexLLM::Provider.register :vertexai, LexLLM::Providers::VertexAI
LexLLM::Provider.register :xai, LexLLM::Providers::XAI

if defined?(Rails::Railtie)
  require 'lex_llm/railtie'
  require 'lex_llm/active_record/acts_as'
end
