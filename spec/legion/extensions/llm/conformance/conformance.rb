# frozen_string_literal: true

# Conformance kit: shared RSpec example groups for N×N canonical routing.
#
# Ship location: spec/legion/extensions/llm/conformance/
# Module: Canonical::Conformance
#
# Consumer pattern (in provider gem spec_helper) — load the kit's example
# modules BY EXPLICIT NAME. Do NOT glob the kit dir: it also ships lex-llm's
# own self-test specs (echo_translator_spec, ssot_*_conformance_spec) plus
# their support files, which LoadError outside this repo.
#   kit = File.join(Gem.loaded_specs['lex-llm'].full_gem_path,
#                   'spec/legion/extensions/llm/conformance')
#   %w[conformance.rb canonical_type_examples.rb client_translator_examples.rb
#       provider_translator_examples.rb provider_tool_rendering_examples.rb
#       ssot_contract_examples.rb ssot_provider_examples.rb].each do |f|
#     require File.join(kit, f)
#   end
#
# Then in specs:
#   it_behaves_like 'a canonical provider translator', described_class
#   it_behaves_like 'a canonical client translator', described_class

module Canonical
  module Conformance
    class << self
      def fixtures_path
        @fixtures_path ||= File.expand_path('fixtures', __dir__)
      end

      def fixture(name)
        path = File.join(fixtures_path, "#{name}.json")
        raise ArgumentError, "Fixture not found: #{name}" unless File.exist?(path)

        # Explicit encoding: fixtures contain UTF-8; a bare File.read obeys the
        # ambient locale and breaks in shells without LANG set (CI, tool runners).
        ::JSON.parse(File.read(path, encoding: 'UTF-8'))
      end

      def fixture_symbolized(name)
        deep_symbolize(fixture(name))
      end

      private

      def deep_symbolize(obj)
        case obj
        when Hash then obj.transform_keys(&:to_sym).transform_values { |v| deep_symbolize(v) }
        when Array then obj.map { |v| deep_symbolize(v) }
        else obj
        end
      end
    end
  end
end

require_relative 'canonical_type_examples'
require_relative 'provider_translator_examples'
require_relative 'client_translator_examples'
