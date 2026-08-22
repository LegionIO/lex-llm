# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Fleet
        # Envelope/param/message-shape violations at the fleet worker (06 §5):
        # non-Hash wire messages, duplicate param spellings, :model inside
        # params, missing per-operation params, unknown operations. Contract
        # violations are programming/contract errors — never retryable (F6).
        class ContractError < StandardError; end
      end
    end
  end
end
