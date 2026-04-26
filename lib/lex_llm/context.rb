# frozen_string_literal: true

module LexLLM
  # Holds per-call configs
  class Context
    attr_reader :config

    def initialize(config)
      @config = config
      @connections = {}
    end

    def chat(*, **, &)
      Chat.new(*, **, context: self, &)
    end

    def embed(*, **, &)
      Embedding.embed(*, **, context: self, &)
    end

    def paint(*, **, &)
      Image.paint(*, **, context: self, &)
    end

    def connection_for(provider_instance)
      provider_instance.connection
    end
  end
end
