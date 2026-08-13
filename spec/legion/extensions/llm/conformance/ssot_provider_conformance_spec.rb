# frozen_string_literal: true

require 'spec_helper'
require_relative 'ssot_provider_examples'
require_relative '../../../../support/fake_ssot_harness'

# Self-test: the Phase 1 fake harness must satisfy the shared provider examples,
# proving the examples are correct and consumable by every provider PR.
RSpec.describe SpecSupport::FakeSsotHarness do
  let(:ssot_harness) { described_class.new }

  it_behaves_like 'an SSOT v3 provider adapter'
end
