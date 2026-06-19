# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Taxonomies
        TIERS           = %i[direct local fleet cloud frontier].freeze
        TYPES           = %i[inference embedding image audio].freeze
        CIRCUIT_STATES  = %i[closed half_open open].freeze
        HEALTH_KEYS     = %i[circuit_state denied available adjustment].freeze
      end
    end
  end
end
