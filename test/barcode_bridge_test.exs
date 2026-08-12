# test/barcode_bridge_test.exs
#
# CodeRegistry grades gtin/acl13/cip13 as :barcode — "a merge bridged SOLELY by one of these is
# SUSPECT" — but suspicion is not the same as refusal. Most real matches are barcode matches, and
# a listing that carries nothing but a barcode has no other way to attach to anything.
#
# So the rule is narrower than "hold every barcode bridge": hold only when BOTH sides already
# stand alone — each carries a non-barcode code of its own — and the reassignable code is the only
# thing tying them together. That is the shape of an NHSBSA GTIN transfer, and nothing else.

defmodule BarcodeBridgeTest do
  use ExUnit.Case, async: true
  import Substrate, only: [claim: 5]

  @d ~D[2026-01-05]
  @gtin {:gtin, "05012345678900"}

  describe "a barcode still bridges when one side has nothing else" do
    test "a bare barcode listing attaches to a fully identified product" do
      # Shop B knows only the barcode. Refusing the bridge would orphan it for no gain.
      clusters =
        variants([
          listing("A", [{:cnk, "1111111"}, @gtin]),
          listing("B", [@gtin])
        ])

      assert length(clusters) == 1
    end

    test "two bare barcode listings are one product" do
      clusters = variants([listing("A", [@gtin]), listing("B", [@gtin])])

      assert length(clusters) == 1
    end

    test "a shared non-barcode code still bridges normally" do
      clusters =
        variants([
          listing("A", [{:cnk, "1111111"}, {:supplier_ref, "S-9"}]),
          listing("B", [{:cnk, "1111111"}, {:supplier_ref, "S-4"}])
        ])

      assert length(clusters) == 1
    end
  end

  describe "a barcode does not bridge two things that already stand alone" do
    test "two packs with their own supplier references are held apart" do
      # The NHSBSA case: one barcode, two dm+d packs, each with its own reference and no
      # national code anywhere. Today this fused silently.
      clusters =
        variants([
          listing("100g", [@gtin, {:supplier_ref, "AMPP-100g"}]),
          listing("30g", [@gtin, {:supplier_ref, "AMPP-30g"}])
        ])

      assert length(clusters) == 2
    end

    test "the held barcode is reported as a conflict, not silently dropped" do
      events =
        decide([
          listing("100g", [@gtin, {:supplier_ref, "AMPP-100g"}]),
          listing("30g", [@gtin, {:supplier_ref, "AMPP-30g"}])
        ])

      assert Enum.any?(events, &match?(%Events.ConflictFlagged{subject: {:identity_conflict, @gtin}}, &1))
      assert Enum.any?(events, &match?(%Events.ConflictFlagged{subject: {:merge, _}}, &1))
    end

    test "the hold does not depend on the order the listings arrive in" do
      claims = [
        listing("100g", [@gtin, {:supplier_ref, "AMPP-100g"}]),
        listing("30g", [@gtin, {:supplier_ref, "AMPP-30g"}])
      ]

      assert variants(claims) == variants(Enum.reverse(claims))
      assert length(variants(claims)) == 2
    end

    test "trusted same evidence overrides the hold" do
      clusters =
        variants([
          listing("100g", [@gtin, {:supplier_ref, "AMPP-100g"}]),
          listing("30g", [@gtin, {:supplier_ref, "AMPP-30g"}]),
          evidence(:same, {:supplier_ref, "AMPP-100g"}, {:supplier_ref, "AMPP-30g"})
        ])

      assert length(clusters) == 1
    end
  end

  describe "the rule leaves the existing national-code guard alone" do
    test "two different national codes on one barcode are still held" do
      clusters =
        variants([
          listing("A", [{:cnk, "1111111"}, @gtin]),
          listing("B", [{:cnk, "2222222"}, @gtin])
        ])

      assert length(clusters) == 2
    end

    test "a non-barcode code bridging two stand-alone sides still fuses" do
      # Only barcodes are suspect. A shared CNK joining two supplier listings is exactly the
      # match the system exists to make.
      clusters =
        variants([
          listing("A", [{:cnk, "1111111"}, {:supplier_ref, "S-9"}]),
          listing("B", [{:cnk, "1111111"}, {:supplier_ref, "S-4"}, @gtin])
        ])

      assert length(clusters) == 1
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp listing(ref, codes), do: claim(:supplier, :identity, %{ref: ref, codes: codes}, @d, @d)

  defp evidence(relation, left, right),
    do: claim(:steward, :identity_evidence, %{relation: relation, left: left, right: right}, @d, @d)

  defp variants(claims), do: claims |> stamp() |> Substrate.current() |> Cluster.variants()

  defp decide(claims) do
    IdentityLedger.decide(IdentityLedger.new(), {:reconcile, variants(claims), @d})
  end

  defp stamp(claims), do: Enum.map(Enum.with_index(claims, 1), fn {c, i} -> %{c | order: i} end)
end
