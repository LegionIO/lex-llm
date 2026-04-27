# frozen_string_literal: true

if defined?(Rails::Railtie)
  module LexLLM
    # Rails integration for LexLLM
    class Railtie < Rails::Railtie
      initializer 'lex_llm.inflections' do
        ActiveSupport::Inflector.inflections(:en) do |inflect|
          inflect.acronym 'LexLLM'
        end
      end

      initializer 'lex_llm.active_record' do
        ActiveSupport.on_load :active_record do
          if LexLLM.config.use_new_acts_as
            require 'lex_llm/active_record/acts_as'
            ::ActiveRecord::Base.include LexLLM::ActiveRecord::ActsAs
          else
            require 'lex_llm/active_record/acts_as_legacy'
            ::ActiveRecord::Base.include LexLLM::ActiveRecord::ActsAsLegacy

            Rails.logger.warn(
              "\n!!! LexLLM's legacy acts_as API is deprecated and will be removed in LexLLM 2.0.0. " \
              "Please consult the migration guide at https://github.com/LegionIO/lex-llm\n"
            )
          end
        end
      end

      rake_tasks do
        load 'tasks/lex_llm.rake'
      end
    end
  end
end
