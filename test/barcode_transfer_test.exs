# test/barcode_transfer_test.exs
#
# A barcode is not a permanent name for a product. NHSBSA publishes a GTIN Transfer Tracking Log
# recording GTINs that moved from one dm+d pack to another — because the pack changed size, because
# the code was recorded against the wrong product, or because a company was taken over.
#
# So a surrogate key must never follow a barcode. It belongs to whichever cluster CONTINUES what
# the key already meant, and national codes (assigned once, never reissued) decide that — not the
# barcode, which is explicitly reassignable.

alias GoldenRecord.{Events, Codes, Substrate, Cluster, IdentityLedger}

defmodule BarcodeTransferTest do
  use ExUnit.Case, async: true
  import Substrate, only: [claim: 5]

  @w1 ~D[2026-01-05]
  @w2 ~D[2026-01-12]
  @gtin {:gtin, "05012345678900"}

  describe "a transferred barcode does not take the surrogate key with it" do
    test "the key stays with the pack that keeps its national code" do
      # Week 1: SK_1 IS the 100 g pack — cnk 1111111, carrying the barcode.
      ledger = week(IdentityLedger.new(), [listing("100g", [{:cnk, "1111111"}, @gtin])], @w1)
      assert ledger.members == %{"SK_1" => codes([{:cnk, "1111111"}, @gtin])}

      # Week 2: the barcode moves to the 30 g pack, which has its own national code.
      ledger =
        week(
          ledger,
          [
            listing("100g", [{:cnk, "1111111"}]),
            listing("30g", [{:cnk, "2222222"}, @gtin])
          ],
          @w2
        )

      # SK_1 must still mean the 100 g pack. The barcode left; the key did not go with it.
      assert ledger.members["SK_1"] == codes([{:cnk, "1111111"}])
      assert ledger.members["SK_2"] == codes([{:cnk, "2222222"}, @gtin])
    end

    test "with no national codes anywhere, the key stays with the pack keeping its own reference" do
      ledger =
        week(
          IdentityLedger.new(),
          [listing("100g", [@gtin, {:supplier_ref, "AMPP-100g"}])],
          @w1
        )

      assert ledger.members == %{"SK_1" => codes([@gtin, {:supplier_ref, "AMPP-100g"}])}

      ledger =
        week(
          ledger,
          [
            listing("100g", [{:supplier_ref, "AMPP-100g"}]),
            listing("30g", [@gtin, {:supplier_ref, "AMPP-30g"}])
          ],
          @w2
        )

      # supplier_ref is not a reassignable barcode, so it outranks the GTIN for continuity.
      assert ledger.members["SK_1"] == codes([{:supplier_ref, "AMPP-100g"}])
    end

    test "the outcome does not depend on the order the listings arrive in" do
      before = week(IdentityLedger.new(), [listing("100g", [{:cnk, "1111111"}, @gtin])], @w1)

      after_transfer = [
        listing("100g", [{:cnk, "1111111"}]),
        listing("30g", [{:cnk, "2222222"}, @gtin])
      ]

      forward = week(before, after_transfer, @w2)
      reversed = week(before, Enum.reverse(after_transfer), @w2)

      assert forward.members == reversed.members
      assert forward.members["SK_1"] == codes([{:cnk, "1111111"}])
    end
  end

  describe "an established key that loses a national code is not allowed to change quietly" do
    test "replacing the national code on a live key is flagged" do
      ledger = week(IdentityLedger.new(), [listing("r", [{:cnk, "1111111"}, @gtin])], @w1)

      # Same single listing, same barcode — but the national code has been swapped underneath it.
      events = decide(ledger, [listing("r", [{:cnk, "2222222"}, @gtin])], @w2)

      assert Enum.any?(events, &match?(%Events.ConflictFlagged{subject: {:identity_swap, "SK_1"}}, &1))
    end

    test "gaining a second national code is an alias, not a swap, and is not flagged" do
      ledger = week(IdentityLedger.new(), [listing("r", [{:cnk, "1111111"}, @gtin])], @w1)
      events = decide(ledger, [listing("r", [{:cnk, "1111111"}, {:cnk, "2222222"}, @gtin])], @w2)

      refute Enum.any?(events, &match?(%Events.ConflictFlagged{subject: {:identity_swap, _}}, &1))
    end

    test "an ordinary attribute-only change does not flag anything" do
      ledger = week(IdentityLedger.new(), [listing("r", [{:cnk, "1111111"}, @gtin])], @w1)
      events = decide(ledger, [listing("r", [{:cnk, "1111111"}, @gtin])], @w2)

      refute Enum.any?(events, &match?(%Events.ConflictFlagged{}, &1))
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp listing(ref, codes), do: claim(:nhsbsa, :identity, %{ref: ref, codes: codes}, @w1, @w1)

  defp codes(list), do: MapSet.new(Enum.map(list, &Codes.canonicalize/1))

  defp decide(ledger, claims, at) do
    stamped = Enum.map(Enum.with_index(claims, 1), fn {c, i} -> %{c | order: i} end)
    IdentityLedger.decide(ledger, {:reconcile, Cluster.variants(Substrate.current(stamped)), at})
  end

  defp week(ledger, claims, at) do
    ledger
    |> decide(claims, at)
    |> Enum.reduce(ledger, &IdentityLedger.evolve(&2, &1))
  end
end
