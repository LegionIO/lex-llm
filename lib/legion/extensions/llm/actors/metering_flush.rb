# frozen_string_literal: true

module Legion
  module Extensions
    module Llm
      module Actor
        # Periodically drains the LLM metering spool.
        #
        # Metering events are emitted by legion-llm's Legion::LLM::Metering. When
        # transport is down at emit time they are appended to a durable JSONL
        # spool (~/.legionio/data/spool/metering/events.jsonl) instead of being
        # published to the `llm.metering` exchange. Nothing was draining that
        # spool after lex-llm-gateway was retired, so events accumulated forever.
        #
        # flush_spool reads every spooled event — chat, embeddings, skills, all
        # funnel through Legion::LLM::Metering.emit into the same file — and
        # republishes each to the exchange, then truncates. It is a no-op when
        # transport is unavailable, so it is safe to tick every minute.
        #
        # runner_class points at legion-llm (the higher gem, always loaded at
        # full boot). lex-llm must not require legion-llm — that would be circular
        # (legion-llm depends on lex-llm) — so we reference it by string and let
        # the actor base resolve the constant at tick time via const_get.
        #
        # NOT a singleton actor: every node runs LegionIO independently and owns
        # its own spool file, so each node must drain its own spool. Leader
        # election would strand every non-leader node's spool.
        class MeteringFlush < Legion::Extensions::Actors::Every
          def runner_class
            'Legion::LLM::Metering'
          end

          def runner_function
            'flush_spool'
          end

          def time
            60
          end

          def run_now?
            false
          end

          def use_runner?
            false
          end

          def check_subtask?
            false
          end

          def generate_task?
            false
          end
        end
      end
    end
  end
end
