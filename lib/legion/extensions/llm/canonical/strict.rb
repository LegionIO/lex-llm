# frozen_string_literal: true

# -- module doc is in canonical.rb entry point
module Legion
  module Extensions
    module Llm
      # -- required for Data.define block scope
      module Canonical
        # Shared strict-factory guards (04 L1/L3/L5/L6) — one implementation for
        # every type. Nil or wrong-class input raises ArgumentError naming the
        # site, member, and offending class. No factory returns nil; unknown
        # keys fold into the metadata member (no drops, no raises).
        #
        # H1: every type installs a validated `.new` (a single strict
        # constructor). `.new`, `.build`, and `.from_hash` all run the same
        # member contract — a `.new`-minted object cannot carry poison past
        # the class-membership boundaries (enforce_canonical_messages!,
        # fleet W4 rehydration, the conformance kit).
        module Strict
          module_function

          # H1: install the strict `.new` on a Data type. The C-level
          # constructor is preserved as the PRIVATE `data_define_new` (used
          # only by the strict `.new` itself); the public `.new` maps the
          # call shape (member_values!), runs the type's member contract
          # (validate, a ->(values, site) block returning the normalized
          # values), and delegates. Every construction path — .new, .build,
          # .from_hash — funnels through the same contract.
          def install_strict_new!(type_class, &validate)
            singleton = type_class.singleton_class
            singleton.alias_method(:data_define_new, :new)
            singleton.send(:private, :data_define_new)

            singleton.define_method(:new) do |*args, **kwargs|
              values = Strict.member_values!(self, self::NEW_SITE, args, kwargs)
              values = validate.call(values, self::NEW_SITE)
              data_define_new(**values)
            end
          end

          # Map raw `.new` arguments (positional or keyword form) onto a
          # member => value Hash. Wrong call shapes raise a typed
          # ArgumentError naming the site: mixing both forms, a positional
          # count mismatch, or an unknown member. Members absent from the
          # call map to nil and follow each member's own contract.
          def member_values!(type_class, site, args, kwargs)
            members = type_class.members
            raise ArgumentError, "#{site}: pass either positional or keyword members, not both" if args.any? && kwargs.any?

            if args.any?
              raise ArgumentError, "#{site}: expected #{members.size} positional members, got #{args.size}" unless args.size == members.size

              return members.zip(args).to_h
            end

            unknown = kwargs.keys - members.map(&:to_sym)
            raise ArgumentError, "#{site}: unknown member(s) #{unknown.sort.join(', ')}" unless unknown.empty?

            members.to_h { |member| [member, kwargs[member]] }
          end

          def require_hash!(source, site)
            return source if source.is_a?(::Hash)

            raise ArgumentError, "#{site}: expected Hash, got #{source.class}"
          end

          def symbolize_keys(hash)
            hash.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          end

          # 04 L5: unknown keys fold into the metadata member.
          def fold_unknowns!(type_class, site, hash)
            metadata = metadata!(hash.delete(:metadata), site)
            known = type_class.members.map(&:to_sym)
            (hash.keys - known).each { |key| metadata[key] = hash.delete(key) }
            metadata
          end

          def metadata!(value, site, member: :metadata)
            return {} if value.nil?

            raise ArgumentError, "#{site}: #{member} expected Hash, got #{value.class}" unless value.is_a?(::Hash)

            value
          end

          def enum!(value, allowed, site, member)
            return value if value.nil? || allowed.include?(value)

            raise ArgumentError,
                  "#{site}: Invalid #{member}: #{value.inspect}. Must be one of: #{allowed.join(', ')}"
          end

          def expect_type!(value, allowed, site, member)
            return value if value.nil? || allowed.any? { |klass| value.is_a?(klass) }

            raise ArgumentError,
                  "#{site}: #{member} expected #{allowed.map(&:name).join(' | ')}, got #{value.class}"
          end
        end
      end
    end
  end
end
