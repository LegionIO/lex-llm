# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Extensions::Llm::Utils do
  describe '.localhost_url?' do
    it 'detects loopback hosts in URLs and bare host[:port] values' do
      expect(described_class.localhost_url?('http://localhost:11434/v1')).to be(true)
      expect(described_class.localhost_url?('http://127.0.0.1:11434/v1')).to be(true)
      expect(described_class.localhost_url?('http://[::1]:11434/v1')).to be(true)
      expect(described_class.localhost_url?('localhost:11434')).to be(true)
      expect(described_class.localhost_url?('127.0.0.1:11434')).to be(true)
    end

    it 'rejects non-loopback hosts and garbage' do
      expect(described_class.localhost_url?('http://apollo:11434/v1')).to be(false)
      expect(described_class.localhost_url?('not a url at all')).to be(false)
      expect(described_class.localhost_url?('')).to be(false)
    end

    it 'is the one shared host-locality detector (U15)' do
      expect(Legion::Extensions::Llm::CredentialSources.localhost?('http://localhost:11434')).to be(true)
      expect(Legion::Extensions::Llm::CredentialSources.localhost?('http://apollo:11434')).to be(false)
    end
  end

  describe '.deep_merge (U7 — dup-before-merge policy)' do
    it 'merges nested hashes without mutating the inputs' do
      left = { a: { b: 1 }, keep: 1 }
      right = { a: { c: 2 } }

      merged = described_class.deep_merge(left, right)

      expect(merged).to eq(a: { b: 1, c: 2 }, keep: 1)
      expect(left).to eq(a: { b: 1 }, keep: 1)
    end
  end

  describe '.to_safe_array' do
    it 'returns the same array instance when the input is already an array' do
      items = [1, 2, 3]

      expect(described_class.to_safe_array(items)).to equal(items)
    end

    it 'wraps hashes in an array' do
      hash = { key: 'value' }

      expect(described_class.to_safe_array(hash)).to eq([hash])
    end

    it 'wraps non-collection values in an array' do
      expect(described_class.to_safe_array('value')).to eq(['value'])
    end
  end

  describe '.deep_merge' do
    it 'merges nested hashes without mutating the originals' do
      original = { config: { retries: 3, timeout: 5 }, mode: :safe }
      overrides = { config: { timeout: 10 }, verbose: true }

      result = described_class.deep_merge(original, overrides)

      expect(result).to eq(
        config: { retries: 3, timeout: 10 },
        mode: :safe,
        verbose: true
      )
      expect(original).to eq(config: { retries: 3, timeout: 5 }, mode: :safe)
      expect(overrides).to eq(config: { timeout: 10 }, verbose: true)
    end
  end

  describe '.deep_dup' do
    it 'duplicates nested arrays and hashes' do
      original = {
        metadata: {
          tags: %w[ruby llm],
          info: { version: '1.0.0' }
        }
      }

      duplicate = described_class.deep_dup(original)

      expect(duplicate).to eq(original)
      expect(duplicate).not_to equal(original)
      expect(duplicate[:metadata]).not_to equal(original[:metadata])
      expect(duplicate[:metadata][:tags]).not_to equal(original[:metadata][:tags])
      expect(duplicate[:metadata][:info]).not_to equal(original[:metadata][:info])
    end
  end

  describe '.deep_stringify_keys' do
    it 'converts nested keys and symbol values to strings' do
      data = {
        config: {
          retries: 3,
          mode: :safe
        },
        'files' => [{ path: '/tmp/file.txt' }]
      }

      expect(described_class.deep_stringify_keys(data)).to eq(
        'config' => {
          'retries' => 3,
          'mode' => 'safe'
        },
        'files' => [{ 'path' => '/tmp/file.txt' }]
      )
    end
  end

  describe '.deep_symbolize_keys' do
    it 'converts nested string keys to symbols and preserves non-convertible keys' do
      data = {
        'config' => {
          'retries' => 3,
          'mode' => 'safe',
          'options' => [{ 'path' => '/tmp/file.txt' }]
        },
        42 => 'answer'
      }

      result = described_class.deep_symbolize_keys(data)

      expect(result[:config][:retries]).to eq(3)
      expect(result[:config][:mode]).to eq('safe')
      expect(result[:config][:options].first[:path]).to eq('/tmp/file.txt')
      expect(result[42]).to eq('answer')
    end
  end
end
