# frozen_string_literal: true

module LexLLM
  module Routing
    # Describes one concrete model made available by one provider instance.
    class ModelOffering
      attr_reader :provider_family, :instance_id, :transport, :tier, :model, :usage_type, :capabilities, :limits,
                  :credentials, :health, :cost, :policy_tags, :metadata

      def initialize(data)
        @provider_family = normalize_symbol(fetch_value(data, :provider_family, fetch_value(data, :provider)))
        @instance_id = normalize_symbol(fetch_value(data, :instance_id, @provider_family))
        @transport = normalize_symbol(fetch_value(data, :transport, :http))
        @tier = normalize_symbol(fetch_value(data, :tier, default_tier))
        @model = fetch_value(data, :model).to_s
        @usage_type = normalize_usage_type(fetch_value(data, :usage_type,
                                                       fetch_value(data, :type) ||
                                                       fetch_value(data, :kind) ||
                                                       infer_usage_type(data)))
        @capabilities = normalize_array(fetch_value(data, :capabilities))
        @limits = normalize_hash(fetch_value(data, :limits))
        @credentials = fetch_value(data, :credentials)
        @health = normalize_hash(fetch_value(data, :health))
        @cost = normalize_hash(fetch_value(data, :cost))
        @policy_tags = normalize_array(fetch_value(data, :policy_tags)).map(&:to_sym)
        @metadata = normalize_hash(fetch_value(data, :metadata))
      end

      def enabled?
        !metadata.key?(:enabled) || metadata[:enabled] != false
      end

      def embedding?
        usage_type == :embedding
      end

      def inference?
        %i[chat inference completion].include?(usage_type)
      end

      def context_window
        integer_limit(:context_window) || integer_limit(:max_input_tokens)
      end

      def max_output_tokens
        integer_limit(:max_output_tokens)
      end

      def supports?(capability)
        capabilities.include?(capability.to_sym)
      end

      def eligible_for?(usage_type: nil, required_capabilities: [], min_context_window: nil, policy_tags: [])
        return false unless enabled?
        return false unless usage_type_matches?(usage_type)
        return false unless capabilities_match?(required_capabilities)
        return false unless context_window_matches?(min_context_window)
        return false unless policy_tags_match?(policy_tags)

        true
      end

      def lane_key(prefix: 'llm.fleet', include_context: true, include_fingerprint: false)
        LaneKey.for(self, prefix:, include_context:, include_fingerprint:)
      end

      def eligibility_fingerprint
        LaneKey.eligibility_fingerprint(self)
      end

      def to_h
        {
          provider_family: provider_family,
          instance_id: instance_id,
          transport: transport,
          tier: tier,
          model: model,
          usage_type: usage_type,
          capabilities: capabilities,
          limits: limits,
          credentials: credentials,
          health: health,
          cost: cost,
          policy_tags: policy_tags,
          metadata: metadata
        }
      end

      private

      def default_tier
        case @transport
        when :local
          :local
        when :rabbitmq
          :fleet
        else
          :private
        end
      end

      def infer_usage_type(data)
        capabilities = normalize_array(fetch_value(data, :capabilities))
        return :embedding if capabilities.include?(:embedding) || capabilities.include?(:embed)

        :inference
      end

      def normalize_usage_type(value)
        case value.to_sym
        when :embed, :embeddings
          :embedding
        when :completion, :text, :chat
          :inference
        else
          value.to_sym
        end
      end

      def normalize_symbol(value)
        return nil if value.nil?

        value.to_sym
      end

      def normalize_array(value)
        Array(value).compact.map(&:to_sym)
      end

      def normalize_hash(value)
        (value || {}).to_h.transform_keys(&:to_sym)
      end

      def fetch_value(hash, key, default = nil)
        return default unless hash.respond_to?(:key?)

        string_key = key.to_s
        return hash[string_key] if hash.key?(string_key)

        hash.key?(key) ? hash[key] : default
      end

      def usage_type_matches?(expected)
        expected.nil? || normalize_usage_type(expected) == usage_type
      end

      def capabilities_match?(required)
        Array(required).all? { |capability| supports?(capability) }
      end

      def context_window_matches?(minimum)
        minimum.nil? || (!!context_window && context_window >= minimum.to_i)
      end

      def policy_tags_match?(required)
        Array(required).all? { |tag| policy_tags.include?(tag.to_sym) }
      end

      def integer_limit(key)
        value = limits[key]
        return nil if value.nil?

        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
