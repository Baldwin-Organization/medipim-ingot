# test/identity_conflict_explained_test.exs
#
# Plain-language tests, written so a non-technical reader can follow them top to bottom:
# each test states the INPUT in everyday words, then the EXPECTED OUTPUT in everyday words.
# The story: different shops/suppliers describe products using codes (a national code like a
# pharmacy "CNK", and a barcode like a "GTIN"), and the system has to decide when two descriptions
# are really the SAME product.

alias GoldenRecord.{Events, Codes, Substrate, Priority, Cluster, IdentityLedger, History}

defmodule IdentityConflictExplainedTest do
  use ExUnit.Case, async: true
  import Substrate, only: [claim: 5]

  @today ~D[2026-01-01]

  describe "Deciding when two descriptions are the same product" do
    test "WHEN two shops use the SAME barcode, THEN the system treats it as ONE product" do
      # ── INPUT (in plain words) ────────────────────────────────────────────────
      #   Shop A says:  "I have an item with national code 111 and barcode 5012345678900."
      #   Shop B says:  "I have an item with the barcode 5012345678900."
      #   Both used the same barcode.
      result =
        run([
          a_source_says("Shop A", national_code: "111", barcode: "5012345678900"),
          a_source_says("Shop B", barcode: "5012345678900")
        ])

      # ── EXPECTED OUTPUT (in plain words) ──────────────────────────────────────
      #   The system decides the two descriptions are the SAME real product, and combines them
      #   into ONE product that carries both the national code and the barcode.
      assert number_of_products(result) == 1
      assert product_has_code?(result, {:cnk, "111"})
      assert product_has_code?(result, {:gtin, "5012345678900"})
    end

    test "WHEN two shops share a barcode but give DIFFERENT national codes, THEN the system must NOT silently merge them" do
      # ── INPUT (in plain words) ────────────────────────────────────────────────
      #   Shop A says:  "national code 111, barcode 5012345678900."
      #   Shop B says:  "national code 222, barcode 5012345678900."
      #   Same barcode, but two different national codes — a contradiction: a single product
      #   cannot truthfully have two different national codes.
      claims = [
        a_source_says("Shop A", national_code: "111", barcode: "5012345678900"),
        a_source_says("Shop B", national_code: "222", barcode: "5012345678900")
      ]

      results = [run(claims), run(Enum.reverse(claims))]

      # ── EXPECTED OUTPUT, with guarding ON (the behaviour we want) ──────────────
      #   The system does NOT glue 111 and 222 into one product. It keeps them as TWO products
      #   and flags the clash so a person can decide. (Better to under-merge and ask than to
      #   silently fuse two real products into one.)
      for result <- results do
        assert number_of_products(result) == 2
        assert a_clash_was_flagged?(result)
      end

      assert Enum.map(results, &product_codes/1) |> Enum.uniq() |> length() == 1
    end

    test "WHEN a trusted steward confirms the two national codes are aliases, THEN the held match can merge" do
      result =
        run([
          a_source_says("Shop A", national_code: "111", barcode: "5012345678900"),
          a_source_says("Shop B", national_code: "222", barcode: "5012345678900"),
          trusted_evidence(:same, {:cnk, "111"}, {:cnk, "222"})
        ])

      assert number_of_products(result) == 1
      refute a_clash_was_flagged?(result)
      assert product_has_code?(result, {:cnk, "111"})
      assert product_has_code?(result, {:cnk, "222"})
    end

    test "WHEN a trusted steward says two otherwise compatible national codes are distinct, THEN they stay apart" do
      result =
        run([
          claim(
            :"Shop A",
            :identity,
            %{ref: "Shop A", codes: [{:cnk, "111"}, {:gtin, "5012345678900"}]},
            @today,
            @today
          ),
          claim(
            :"Shop B",
            :identity,
            %{ref: "Shop B", codes: [{:pzn, "222"}, {:gtin, "5012345678900"}]},
            @today,
            @today
          ),
          trusted_evidence(:distinct, {:cnk, "111"}, {:pzn, "222"})
        ])

      assert number_of_products(result) == 2
      assert a_clash_was_flagged?(result)
    end

    test "WHEN one product splits but the parts still share a contested barcode, THEN the steward gets a merge proposal" do
      # ── INPUT (in plain words) ────────────────────────────────────────────────
      #   Yesterday the system knew ONE product carrying national codes 111 and 222 plus a barcode.
      #   Today the sources describe TWO products — 111 with the barcode, and 222 with the barcode.
      #   The barcode is contested (both sides claim it), so the split parts might still be one product.
      prior = %Events.IdentityMinted{
        key: "SK_1",
        codes: MapSet.new([{:cnk, "111"}, {:cnk, "222"}, {:gtin, "5012345678900"}]),
        recorded_at: @today,
        order: 1
      }

      clusters = [
        MapSet.new([{:cnk, "111"}, {:gtin, "5012345678900"}]),
        MapSet.new([{:cnk, "222"}, {:gtin, "5012345678900"}])
      ]

      events =
        IdentityLedger.new()
        |> IdentityLedger.evolve(prior)
        |> IdentityLedger.decide({:reconcile, clusters, @today})

      # ── EXPECTED OUTPUT (in plain words) ──────────────────────────────────────
      #   The key splits in two, AND the shared barcode puts the two new keys in front of a
      #   steward as a merge proposal — the split must not silently swallow the question.
      assert Enum.any?(events, &match?(%Events.IdentitySplit{key: "SK_1"}, &1))
      assert Enum.any?(events, &match?(%Events.ConflictFlagged{subject: {:merge, ["SK_1", "SK_2"]}}, &1))
    end
  end

  # ── tiny helpers that turn the plain-language story into engine claims/calls ──

  defp a_source_says(name, fields) do
    codes =
      [
        fields[:national_code] && {:cnk, fields[:national_code]},
        fields[:barcode] && {:gtin, fields[:barcode]}
      ]
      |> Enum.reject(&is_nil/1)

    claim(String.to_atom(name), :identity, %{ref: name, codes: codes}, @today, @today)
  end

  defp trusted_evidence(relation, left, right) do
    claim(:steward, :identity_evidence, %{relation: relation, left: left, right: right}, @today, @today)
  end

  defp run(claims) do
    {stamped, next} = stamp(claims, 1)

    decisions =
      IdentityLedger.decide(
        IdentityLedger.new(),
        {:reconcile, Cluster.variants(Substrate.current(stamped)), @today}
      )

    {decisions, _} = stamp(decisions, next)
    log = stamped ++ decisions
    %{log: log, products: History.now(log, Priority.new(%{}, []))}
  end

  defp number_of_products(%{products: products}), do: length(Enum.flat_map(products, & &1.variants))

  defp product_has_code?(%{products: products}, code) do
    products |> Enum.flat_map(& &1.variants) |> Enum.any?(&(Codes.canonicalize(code) in &1.codes))
  end

  defp a_clash_was_flagged?(%{log: log}) do
    Enum.any?(log, fn
      %Events.ConflictFlagged{subject: {:identity_conflict, {:gtin, _}}} -> true
      _ -> false
    end)
  end

  defp product_codes(%{products: products}) do
    products
    |> Enum.flat_map(& &1.variants)
    |> Enum.map(& &1.codes)
    |> Enum.sort()
  end

  defp stamp(events, start),
    do: {Enum.map(Enum.with_index(events, start), fn {e, i} -> %{e | order: i} end), start + length(events)}
end
