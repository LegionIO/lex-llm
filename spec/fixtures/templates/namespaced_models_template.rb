# frozen_string_literal: true

gem 'lex-llm', path: ENV['LEX_LLM_PATH'] || '../../../..', require: 'lex_llm'

generate 'lex_llm:install',
         'chat:Llm::Chat',
         'message:Llm::Message',
         'model:Llm::Model',
         'tool_call:Llm::ToolCall'
rails_command 'db:migrate'
generate 'lex_llm:chat_ui',
         'chat:Llm::Chat',
         'message:Llm::Message',
         'model:Llm::Model'
