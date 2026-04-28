# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'rbconfig'

RSpec.describe Legion::Extensions::Llm::Attachment do
  it 'supports path attachments from the public API' do
    script = <<~'RUBY'
      require 'legion/extensions/llm'

      content = Legion::Extensions::Llm::Content.new('What is in this file?', 'spec/fixtures/ruby.txt')
      attachment = content.attachments.first
      puts "#{attachment.filename},#{attachment.mime_type}"
    RUBY

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, '-Ilib', '-e', script,
      chdir: File.expand_path('../../../..', __dir__)
    )

    expect(status.success?).to be(true), stderr
    expect(stdout.strip).to eq('ruby.txt,text/plain')
  end
end
