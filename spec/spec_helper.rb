# frozen_string_literal: true

begin
  require 'dotenv/load'
rescue LoadError
  nil
end

begin
  require 'simplecov'
  require 'simplecov-cobertura'
  require_relative 'support/simplecov_configuration'
rescue LoadError
  nil
end

require 'bundler/setup'
require 'fileutils'
require 'tempfile'
require 'legion/extensions/llm'
require 'ruby_llm/schema'
require_relative 'support/rspec_configuration'
require_relative 'support/llm_configuration'
require_relative 'support/fake_llm_provider'
