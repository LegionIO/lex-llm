# frozen_string_literal: true

require 'rails/generators'

module LexLLM
  module Generators
    # Generator for LexLLM schema classes.
    class SchemaGenerator < Rails::Generators::NamedBase
      source_root File.expand_path('templates', __dir__)

      namespace 'lex_llm:schema'

      desc 'Creates a LexLLM schema class'

      def create_schema_file
        template 'schema.rb.tt', File.join('app/schemas', class_path, "#{file_name}.rb")
      end

      private

      def schema_class_name
        class_name.end_with?('Schema') ? class_name : "#{class_name}Schema"
      end
    end
  end
end
