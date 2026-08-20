# frozen_string_literal: true

require 'legion/extensions/llm/inventory/errors'
require 'legion/extensions/llm/inventory/immutable_value'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/routing/records'
require 'legion/extensions/llm/taxonomies'

module Legion
  module Extensions
    module Llm
      module Routing
        # A provider-neutral normalized outcome. Adapters translate wire errors
        # into one of these kinds; the common classifier branches only on kind,
        # never on provider identity. The value contains no provider object,
        # callable, response body, routing weight, or health-mutation
        # instruction. HTTP 503/529 alone is not an input and cannot manufacture
        # instance_unavailable. See phase-1-lex-llm-additive.md section 14.2.
        ProviderOutcome = ::Data.define(:kind, :reason, :quota_domain, :retry_after, :metadata) do
          def initialize(kind:, reason:, quota_domain: nil, retry_after: nil, metadata: {})
            support = Legion::Extensions::Llm::Inventory::RecordSupport
            errors = Legion::Extensions::Llm::Inventory::Errors
            raise errors::ValidationError, 'kind must be a Taxonomies::PROVIDER_OUTCOMES value' unless Legion::Extensions::Llm::Taxonomies::PROVIDER_OUTCOMES.include?(kind)

            super(
              kind: kind,
              reason: support.sanitized_reason(value: reason, field: :reason),
              quota_domain: validate_quota_domain!(kind, quota_domain),
              retry_after: validate_retry_after!(retry_after),
              metadata: support.frozen_metadata(value: metadata)
            )
          end

          def validate_quota_domain!(kind, quota_domain)
            errors = Legion::Extensions::Llm::Inventory::Errors
            return nil if quota_domain.nil?
            raise errors::ValidationError, 'quota_domain must be a Routing::QuotaDomainKey' unless quota_domain.is_a?(QuotaDomainKey)
            raise errors::ValidationError, 'quota_domain is allowed only for rate_limited' unless kind == :rate_limited

            quota_domain
          end

          def validate_retry_after!(retry_after)
            return nil if retry_after.nil?
            return retry_after if retry_after.is_a?(::Numeric) && retry_after.finite? && !retry_after.negative?

            raise Legion::Extensions::Llm::Inventory::Errors::ValidationError,
                  'retry_after must be nil or a finite nonnegative Numeric'
          end

          # The ONE error→kind base table (05 O6 / 08 E1). Providers override
          # #normalize_dispatch_error only when their wire semantics supply
          # stronger evidence; the table itself is frozen here and is also the
          # source of fleet retryability (06 F6).
          def self.kind_for(error)
            case error
            when OverloadedError then :overloaded
            when RateLimitError then :rate_limited
            when UnauthorizedError then :authentication
            when PaymentRequiredError then :billing
            when ForbiddenError then :authorization
            when ContextLengthExceededError then :context_rejected
            when BadRequestError then :invalid_request
            when ModelNotFoundError then :model_missing
            when ModelNotAllowedError then :policy
            when Faraday::TimeoutError, Timeout::Error then :timeout
            when Faraday::ConnectionFailed, Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError then :connection_failure
            else :provider_error
            end
          end
        end

        # 06 F6: the transient kinds that may be retried at the fleet edge.
        # Classification/contract/auth/policy kinds never retry.
        ProviderOutcome::RETRYABLE_KINDS = %i[overloaded rate_limited timeout connection_failure provider_error].freeze
      end
    end
  end
end
