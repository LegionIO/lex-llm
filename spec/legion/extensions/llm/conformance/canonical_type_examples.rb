# frozen_string_literal: true

# 09 §1 — canonical type conformance: the T-groups as shared examples.
#
# The including spec supplies:
#   let(:type_class)  — the Canonical type
#   let(:type_source) — a Hash exercising the members (from_hash input)
#   optionally:
#     let(:auto_generated_members) — member names filled by the factory when
#     absent from the source (id, timestamp), excluded from member-equality
#     checks.
#
# Type-specific laws (T4 member survival, T5 enum law, T7 member normalization
# for the type's normalizable members) are asserted in each type spec.

RSpec.shared_examples 'a canonical type' do
  let(:type) { type_class }
  let(:built) { type.from_hash(type_source) }

  describe 'T1 — strict input' do
    it 'raises a typed ArgumentError on nil (no nil factory)' do
      expect { type.from_hash(nil) }
        .to raise_error(ArgumentError, /expected Hash, got NilClass/)
    end

    it 'raises a typed ArgumentError naming the offending class on wrong-class input' do
      expect { type.from_hash('not a hash') }
        .to raise_error(ArgumentError, /expected Hash, got String/)
      expect { type.from_hash(42) }
        .to raise_error(ArgumentError, /expected Hash, got Integer/)
    end

    it 'never returns nil from from_hash (valid instances or typed raises only)' do
      expect(type.from_hash(type_source)).not_to be_nil
      result =
        begin
          type.from_hash({})
        rescue ArgumentError
          :typed_raise
        end
      expect(result).not_to be_nil
    end
  end

  describe 'T2 — unknown-key policy (04 L5)' do
    it 'folds unknown keys into metadata verbatim — no drops, no raises' do
      source = type_source.merge(fleet_unknown_key: 'kept', other_unknown: [1, 2])
      instance = type.from_hash(source)

      expect(instance.metadata).to include(fleet_unknown_key: 'kept', other_unknown: [1, 2])
    end

    it 'round-trips the folded unknowns' do
      source = type_source.merge(fleet_unknown_key: 'kept')
      instance = type.from_hash(source)
      expect(type.from_hash(instance.to_h).metadata).to include(fleet_unknown_key: 'kept')
    end
  end

  describe 'T3 — round-trip identity (04 L7)' do
    it 'build → to_h → from_hash → Data-equal' do
      expect(type.from_hash(built.to_h)).to eq(built)
    end

    it 'to_h is a plain Hash with symbol keys (no member lost, no key invented)' do
      hash = built.to_h
      expect(hash).to be_a(Hash)
      expect(hash.keys).to all(be_a(Symbol))
      checkable = (type.members.map(&:to_sym) - auto_generated_members)
      checkable.each do |member|
        value = built.public_send(member)
        next if value.nil?

        expect(hash.key?(member)).to be(true)
      end
    end
  end

  describe 'T6 — serialization uniformity (04 L8)' do
    it 'as_json == to_h and to_json == to_h.to_json' do
      expect(built.as_json).to eq(built.to_h)
      expect(built.to_json).to eq(built.to_h.to_json)
    end
  end
end
