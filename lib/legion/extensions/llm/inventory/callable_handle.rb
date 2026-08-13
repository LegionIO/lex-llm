# frozen_string_literal: true

require 'securerandom'
require 'legion/logging'
require 'legion/extensions/llm/inventory/errors'

module Legion
  module Extensions
    module Llm
      module Inventory
        # A dispatch lease over a CallableHandle. Holds the exact provider
        # callable for one in-flight request and releases the reference exactly
        # once. See phase-1-lex-llm-additive.md section 11.4.
        class DispatchLease
          attr_reader :lease_id, :callable

          def initialize(lease_id:, callable_handle:, callable:)
            @lease_id = lease_id.dup.freeze
            @callable_handle = callable_handle
            @callable = callable
            @released = false
          end

          def released?
            @released
          end

          def release
            @callable_handle.__send__(:release_lease, self)
          end

          private

          # Set only by the owning CallableHandle under its private Mutex.
          def mark_released!
            @released = true
          end
        end

        # Owns the acquire/retire lifecycle for one provider callable. The
        # handle's object identity is stable while its state moves
        # ACTIVE -> RETIRING -> DISPOSED under a private Mutex. Retiring an old
        # handle cannot disconnect a distinct new callable because a new claim
        # must supply a distinct callable object. See section 11.4.
        class CallableHandle
          include Legion::Logging::Helper

          attr_reader :handle_id

          def initialize(handle_id:, callable:)
            raise Errors::ValidationError, 'handle_id must be a non-empty String' unless nonempty_string?(handle_id)
            raise Errors::ValidationError, 'callable must not be nil' if callable.nil?

            @handle_id = handle_id.dup.freeze
            @callable = callable
            @state = :active
            @reference_count = 0
            @disposed_with_error = false
            @mutex = Mutex.new
          end

          def state
            @mutex.synchronize { @state }
          end

          def reference_count
            @mutex.synchronize { @reference_count }
          end

          def acquire
            @mutex.synchronize do
              case @state
              when :retiring
                raise Errors::StaleCallableError, "callable handle #{@handle_id} is retiring"
              when :disposed
                raise Errors::CallableDisposedError, "callable handle #{@handle_id} is disposed"
              end

              @reference_count += 1
              DispatchLease.new(
                lease_id: "lease:v1:#{SecureRandom.uuid}", callable_handle: self, callable: @callable
              )
            end
          end

          def retire
            @mutex.synchronize do
              case @state
              when :disposed
                return @disposed_with_error ? :disposed_with_error : :disposed
              when :retiring
                return :retiring
              end

              @state = :retiring
              return :retiring if @reference_count.positive?

              dispose_locked
            end
          end

          private

          def release_lease(lease)
            @mutex.synchronize do
              raise Errors::InvalidTransitionError, 'dispatch lease already released' if lease.released?

              lease.__send__(:mark_released!)
              @reference_count -= 1
              dispose_locked if @reference_count.zero? && @state == :retiring
              nil
            end
          end

          # Caller must hold @mutex. Calls disconnect exactly once and transitions
          # to DISPOSED even when disconnect raises.
          def dispose_locked
            callable = @callable
            callable_class = callable.class.name
            @callable = nil
            begin
              callable.disconnect
              @state = :disposed
              :disposed
            rescue StandardError => e
              @disposed_with_error = true
              @state = :disposed
              handle_exception(
                e, handled: true, level: :warn,
                   operation: 'llm.inventory.callable_handle.dispose',
                   handle_id: @handle_id, callable_class: callable_class
              )
              :disposed_with_error
            end
          end

          def nonempty_string?(value)
            value.is_a?(::String) && !value.strip.empty?
          end
        end
      end
    end
  end
end
