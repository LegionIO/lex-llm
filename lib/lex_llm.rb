# frozen_string_literal: true

require 'base64'
require 'digest/sha1'
require 'event_stream_parser'
require 'faraday'
require 'faraday/multipart'
require 'faraday/retry'
require 'legion/json'
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
    'UI' => 'UI',
    'api' => 'API',
    'llm' => 'LLM',
    'pdf' => 'PDF',
    'lex_llm' => 'LexLLM'
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

if defined?(Rails::Railtie)
  require 'lex_llm/railtie'
  require 'lex_llm/active_record/acts_as'
end
