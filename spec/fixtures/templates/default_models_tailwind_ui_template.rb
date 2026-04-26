# frozen_string_literal: true

gem 'lex-llm', path: ENV['LEX_LLM_PATH'] || ENV['RUBYLLM_PATH'] || '../../../..', require: 'lex_llm'

generate 'lex_llm:install'
rails_command 'db:migrate'
generate 'lex_llm:chat_ui', '--ui=tailwind'
