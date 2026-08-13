# frozen_string_literal: true

require 'spec_helper'
require 'legion/extensions/llm/inventory/callable_handle'

RSpec.describe Legion::Extensions::Llm::Inventory::CallableHandle do
  let(:errors) { Legion::Extensions::Llm::Inventory::Errors }

  # Minimal callable recording exactly-once disconnect; no registry/provider hooks.
  let(:callable_class) do
    Class.new do
      attr_reader :disconnect_count

      def initialize
        @disconnect_count = 0
      end

      def disconnect
        @disconnect_count += 1
      end
    end
  end

  let(:callable) { callable_class.new }
  let(:handle) { described_class.new(handle_id: 'call:v1:test', callable: callable) }

  describe 'construction' do
    it 'starts ACTIVE with zero references' do
      expect(handle.state).to eq(:active)
      expect(handle.reference_count).to eq(0)
      expect(handle.handle_id).to eq('call:v1:test')
    end

    it 'rejects an empty handle_id and a nil callable' do
      expect { described_class.new(handle_id: '', callable: callable) }.to raise_error(errors::ValidationError)
      expect { described_class.new(handle_id: 'call:v1:x', callable: nil) }.to raise_error(errors::ValidationError)
    end
  end

  describe '#acquire' do
    it 'increments the reference count and returns a lease exposing the exact callable' do
      lease = handle.acquire
      expect(handle.reference_count).to eq(1)
      expect(lease.callable).to equal(callable)
      expect(lease).not_to be_released
    end

    it 'returns independent leases with distinct ids' do
      a = handle.acquire
      b = handle.acquire
      expect(handle.reference_count).to eq(2)
      expect(a.lease_id).not_to eq(b.lease_id)
    end

    it 'does not disconnect while leases are released back (error/cancellation/stream-close simulation)' do
      lease = handle.acquire
      lease.release
      expect(lease).to be_released
      expect(handle.reference_count).to eq(0)
      expect(callable.disconnect_count).to eq(0)
      expect(handle.state).to eq(:active)
    end
  end

  describe '#retire' do
    it 'disposes immediately and disconnects once when idle' do
      expect(handle.retire).to eq(:disposed)
      expect(handle.state).to eq(:disposed)
      expect(callable.disconnect_count).to eq(1)
    end

    it 'moves to RETIRING while a lease is outstanding and blocks new acquisition' do
      lease = handle.acquire
      expect(handle.retire).to eq(:retiring)
      expect(handle.state).to eq(:retiring)
      expect { handle.acquire }.to raise_error(errors::StaleCallableError)
      expect(callable.disconnect_count).to eq(0)

      lease.release
      expect(handle.state).to eq(:disposed)
      expect(callable.disconnect_count).to eq(1)
    end

    it 'raises CallableDisposedError on acquire after disposal' do
      handle.retire
      expect { handle.acquire }.to raise_error(errors::CallableDisposedError)
    end

    it 'disconnects exactly once even with multiple leases' do
      a = handle.acquire
      b = handle.acquire
      handle.retire
      a.release
      expect(callable.disconnect_count).to eq(0)
      b.release
      expect(callable.disconnect_count).to eq(1)
      expect(handle.state).to eq(:disposed)
    end
  end

  describe 'release safety' do
    it 'raises on duplicate release and does not decrement twice' do
      a = handle.acquire
      b = handle.acquire
      a.release
      expect { a.release }.to raise_error(errors::InvalidTransitionError)
      expect(handle.reference_count).to eq(1)
      b.release
      expect(handle.reference_count).to eq(0)
    end
  end

  describe 'disconnect failure' do
    let(:callable_class) do
      Class.new do
        def disconnect
          raise StandardError, 'boom'
        end
      end
    end

    it 'still becomes DISPOSED and returns :disposed_with_error without raising' do
      expect(handle.retire).to eq(:disposed_with_error)
      expect(handle.state).to eq(:disposed)
    end
  end
end
