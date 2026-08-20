# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Inventory
        # Typed contract/validation/fencing/transition/acquisition errors for the
        # SSOT v3 runtime contract. See phase-1-lex-llm-additive.md section 7.
        #
        # ValidationError descends from ArgumentError because it signals a caller
        # supplying an invalid field; every other error descends from Error so a
        # consumer can rescue the whole inventory family with one class.
        #
        # Validation errors identify the invalid field but never include
        # credentials, raw endpoints containing secrets, callable inspection, or
        # publisher tokens.
        module Errors
          class Error < StandardError; end
          class ValidationError < ArgumentError; end
          class UnknownInstanceError < Error; end
          class FencedPublisherError < Error; end
          class StaleSequenceError < Error; end
          class InvalidProbeError < Error; end
          class InvalidTransitionError < Error; end
          class UnknownCallableError < Error; end
          class StaleCallableError < Error; end
          class CallableDisposedError < Error; end
          class ExactOfferingMismatchError < Error; end
        end
      end
    end
  end
end
