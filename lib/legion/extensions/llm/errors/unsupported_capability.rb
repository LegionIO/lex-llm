# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Errors
        # Raised when a provider receives a canonical call for an unsupported capability.
        class UnsupportedCapability < StandardError
          attr_reader :provider, :capability, :model

          def initialize(provider:, capability:, model: nil)
            @provider = provider
            @capability = capability
            @model = model
            super("Provider #{provider} does not support #{capability}#{" for #{model}" if model}")
          end
        end
      end
    end
  end
end
