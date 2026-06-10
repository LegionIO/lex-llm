# frozen_string_literal: true

# Conformance kit: shared RSpec example groups for N×N canonical routing.
#
# Ship location: spec/legion/extensions/llm/conformance/
# Module: Canonical::Conformance
#
# Consumer pattern (in provider gem spec_helper):
#   kit = File.join(Gem.loaded_specs['lex-llm'].full_gem_path,
#                   'spec/legion/extensions/llm/conformance')
#   Dir[File.join(kit, '**', '*.rb')].sort.each { |f| require f }
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

require_relative 'provider_translator_examples'
require_relative 'client_translator_examples'
