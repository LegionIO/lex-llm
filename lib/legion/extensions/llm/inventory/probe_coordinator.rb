# frozen_string_literal: true

require 'legion/logging'
require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/probe_token'

module Legion
  module Extensions
    module Llm
      module Inventory
        # Enqueue-only probe handle with per-instance/revision coalescing and
        # single-flight state. It owns no timer, thread, thread pool, provider
        # API call, or registry transition. It is the `probe_request_handle`
        # passed to Registry.claim_instance. See phase-1-lex-llm-additive.md
        # section 13.2.
        class ProbeCoordinator
          include Legion::Logging::Helper

          def initialize(instance_key:, enqueue:)
            raise Errors::ValidationError, 'instance_key must be an InstanceKey' unless instance_key.is_a?(Identity::InstanceKey)
            raise Errors::ValidationError, 'enqueue must be provided' if enqueue.nil?

            @instance_key = instance_key
            @enqueue = enqueue
            @pending = nil
            @in_flight_form = nil
            @in_flight_request = nil
            @mutex = Mutex.new
          end

          # Registry calls this after a root swap on dispatch_instance_unavailable.
          def enqueue_probe_request(instance_key:, publisher_token_id:, unavailable_revision:, reason:)
            request = ProbeRequest.new(
              instance_key: instance_key, publisher_token_id: publisher_token_id,
              unavailable_revision: unavailable_revision, reason: reason
            )
            raise Errors::ValidationError, 'instance_key mismatch' unless request.instance_key == @instance_key

            to_enqueue = nil
            @mutex.synchronize do
              had_pending = !@pending.nil?
              retain_greater(request)
              to_enqueue = @pending if @in_flight_form.nil? && !had_pending
            end
            return true if to_enqueue.nil?

            run_enqueue(to_enqueue)
          end

          def begin_probe(request: nil)
            @mutex.synchronize do
              return false unless @in_flight_form.nil?

              if request.nil?
                @in_flight_form = :cadence
                @in_flight_request = nil
              else
                raise Errors::ValidationError, 'request must be a ProbeRequest' unless request.is_a?(ProbeRequest)
                return false unless @pending && request.equal?(@pending)

                @in_flight_form = :request
                @in_flight_request = request
                @pending = nil
              end
              true
            end
          end

          def finish_probe(request: nil)
            still_pending = nil
            @mutex.synchronize do
              validate_finish_form!(request)
              @in_flight_form = nil
              @in_flight_request = nil
              still_pending = @pending
            end
            run_enqueue(still_pending) unless still_pending.nil?
            still_pending
          end

          def pending?(unavailable_revision:)
            @mutex.synchronize { !@pending.nil? && @pending.unavailable_revision == unavailable_revision }
          end

          def in_flight?
            @mutex.synchronize { !@in_flight_form.nil? }
          end

          private

          def retain_greater(request)
            @pending = request if @pending.nil? || request.unavailable_revision > @pending.unavailable_revision
          end

          def validate_finish_form!(request)
            if request.nil?
              raise Errors::InvalidTransitionError, 'no cadence probe in flight' unless @in_flight_form == :cadence
            else
              raise Errors::InvalidTransitionError, 'finish request does not match the in-flight probe' unless @in_flight_form == :request && @in_flight_request.equal?(request)
            end
          end

          def run_enqueue(request)
            @enqueue.call(request: request) ? true : false
          rescue StandardError => e
            handle_exception(
              e, handled: true, level: :warn, operation: 'llm.inventory.probe_coordinator.enqueue',
                 provider_family: @instance_key.provider_family, instance_id: @instance_key.instance_id
            )
            false
          end
        end
      end
    end
  end
end
