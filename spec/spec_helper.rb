# frozen_string_literal: true

require 'dotenv/load'
require 'simplecov'
require 'simplecov-cobertura'
require_relative 'support/simplecov_configuration'
require 'bundler/setup'
require 'fileutils'
require 'tempfile'
require 'legion/extensions/llm'
require 'ruby_llm/schema'
require_relative 'support/rspec_configuration'
require_relative 'support/llm_configuration'
require_relative 'support/fake_llm_provider'
