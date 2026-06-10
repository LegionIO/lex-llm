# frozen_string_literal: true

require 'spec_helper'
require_relative 'conformance'
require_relative 'echo_translator'

RSpec.describe Canonical::Conformance::EchoTranslator do
  # Self-test: the echo translator passes both conformance groups,
  # proving the shared example groups work correctly.

  it_behaves_like 'a canonical provider translator', described_class
  it_behaves_like 'a canonical client translator', described_class
end
