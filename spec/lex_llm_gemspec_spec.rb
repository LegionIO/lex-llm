# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe 'lex-llm.gemspec' do
  subject(:gemspec) { Gem::Specification.load(File.expand_path('../lex-llm.gemspec', __dir__)) }

  def runtime_dependency(name)
    gemspec.dependencies.find { |dependency| dependency.type == :runtime && dependency.name == name }
  end

  it 'keeps faraday compatible with Ruby < 4.0' do
    expect(runtime_dependency('faraday').requirement.to_s).to eq('>= 1.10.0')
  end

  it 'keeps faraday-retry compatible with Faraday v1 and v2' do
    expect(runtime_dependency('faraday-retry').requirement.to_s).to eq('>= 1')
  end

  it 'publishes as lex-llm' do
    expect(gemspec.name).to eq('lex-llm')
  end
end
# rubocop:enable RSpec/DescribeClass
