# frozen_string_literal: true

require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'

module Legion
  module Extensions
    module Llm
      module Inventory
        # A structurally immutable, generation-tagged read model of the registry.
        # Lookups return the frozen record or nil and never synthesize a default.
        # `instances_by_key` contains only activated instances;
        # `publication_status_by_key` also contains initializing claims. A caller
        # cannot observe a later inventory-record or generation mutation through
        # an older snapshot; the captured CallableHandle lifecycle is the single
        # intentional exception. See phase-1-lex-llm-additive.md section 11.3.
        class Snapshot
          attr_reader :generation

          def initialize(generation:, instances_by_key:, offerings_by_id:, lanes_by_id:, publication_status_by_key:)
            @generation = generation
            @instances_by_key = order_instances(instances_by_key).freeze
            @offerings_by_id = offerings_by_id.dup.freeze
            @lanes_by_id = lanes_by_id.dup.freeze
            @publication_status_by_key = order_instances(publication_status_by_key).freeze
            @ordered_offerings = @offerings_by_id.keys.sort.map { |id| @offerings_by_id[id] }.freeze
            @ordered_lanes = @lanes_by_id.keys.sort.map { |id| @lanes_by_id[id] }.freeze
            freeze
          end

          def instance(instance_key:)
            @instances_by_key[instance_key]
          end

          def offering(offering_id:)
            @offerings_by_id[offering_id]
          end

          def lane(lane_id:)
            @lanes_by_id[lane_id]
          end

          def lanes_for(instance_key:)
            @ordered_lanes.select { |lane| lane.instance_key == instance_key }.freeze
          end

          def offerings_for(instance_key:)
            @ordered_offerings.select { |offering| offering.instance_key == instance_key }.freeze
          end

          def publication_status(instance_key:)
            @publication_status_by_key[instance_key]
          end

          def each_lane(&block)
            return to_enum(:each_lane) unless block

            @ordered_lanes.each(&block)
          end

          def each_offering(&block)
            return to_enum(:each_offering) unless block

            @ordered_offerings.each(&block)
          end

          def each_instance(&block)
            return to_enum(:each_instance) unless block

            @instances_by_key.each_value(&block)
          end

          def each_publication_status(&block)
            return to_enum(:each_publication_status) unless block

            @publication_status_by_key.each_value(&block)
          end

          private

          # Orders InstanceKey entries by [provider_family bytes, instance_id bytes].
          def order_instances(by_key)
            by_key.keys.sort_by { |key| [key.provider_family.to_s.b, key.instance_id.b] }
                       .to_h { |key| [key, by_key[key]] }
          end
        end
      end
    end
  end
end
