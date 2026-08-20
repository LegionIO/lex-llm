# frozen_string_literal: true

require 'legion/extensions/llm/utils'

module Legion
  module Extensions
    module Llm
      module Fleet
        # The ONE fleet wire-normalization entry (10 U5): typed readers over
        # the raw wire Hash. Every fleet boundary (responder, worker, token
        # validator) reads envelopes through these readers. Data is kept RAW
        # (no eager symbolization) so the worker can still detect duplicate
        # String/Symbol param spellings (W5).
        FleetEnvelope = Struct.new(:data, keyword_init: true) do
          # Wrap a wire payload (Hash) or pass an existing envelope through.
          def self.wrap(payload)
            return payload if payload.is_a?(FleetEnvelope)

            new(data: payload)
          end

          def [](key)
            symbol_key = key.to_sym
            return data[symbol_key] if data.key?(symbol_key)

            data[key.to_s]
          end

          def key?(key)
            data.key?(key.to_sym) || data.key?(key.to_s)
          end

          def fetch(key, default = nil)
            key?(key) ? self[key] : default
          end

          def to_h
            Utils.deep_symbolize_keys(data)
          end

          def protocol_version = self[:protocol_version]
          def request_id = self[:request_id]
          def correlation_id = self[:correlation_id]
          def idempotency_key = self[:idempotency_key]
          def operation = self[:operation]
          def provider = self[:provider]
          def provider_instance = self[:provider_instance]
          def model = self[:model]
          def params = self[:params] || {}
          def reply_to = self[:reply_to]
          def message_context = self[:message_context] || {}
          def trace_context = self[:trace_context] || {}
          def execution_contract = self[:execution_contract]
          def offering_id = self[:offering_id]
          def signed_token = self[:signed_token]
        end
      end
    end
  end
end
