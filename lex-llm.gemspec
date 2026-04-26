# frozen_string_literal: true

require_relative 'lib/lex_llm/version'

Gem::Specification.new do |spec|
  spec.name          = 'lex-llm'
  spec.version       = LexLLM::VERSION
  spec.authors       = ['LegionIO', 'Carmine Paolino']
  spec.email         = ['matthewdiverson@gmail.com']

  spec.summary       = 'Shared LegionIO LLM provider framework'
  spec.description   = 'Provider-neutral LLM primitives, schemas, routing metadata, and shared codecs for LegionIO ' \
                       'LLM provider extensions.'

  spec.homepage      = 'https://github.com/LegionIO/lex-llm'
  spec.license       = 'MIT'
  spec.required_ruby_version = Gem::Requirement.new('>= 3.4')

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/LegionIO/lex-llm'
  spec.metadata['changelog_uri'] = 'https://github.com/LegionIO/lex-llm/blob/main/CHANGELOG.md'
  spec.metadata['documentation_uri'] = 'https://github.com/LegionIO/lex-llm'
  spec.metadata['bug_tracker_uri'] = "#{spec.metadata['source_code_uri']}/issues"

  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(spec|test|features|tmp|coverage)/}) }
  spec.require_paths = ['lib']

  # Runtime dependencies
  spec.add_dependency 'base64'
  spec.add_dependency 'event_stream_parser', '~> 1'
  spec.add_dependency 'faraday', ENV['FARADAY_VERSION'] || '>= 1.10.0'
  spec.add_dependency 'faraday-multipart', '>= 1'
  spec.add_dependency 'faraday-net_http', '>= 1'
  spec.add_dependency 'faraday-retry', '>= 1'
  spec.add_dependency 'marcel', '~> 1'
  spec.add_dependency 'ruby_llm-schema', '~> 0'
  spec.add_dependency 'zeitwerk', '~> 2'
end
