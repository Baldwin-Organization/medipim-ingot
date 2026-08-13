# medipim_policy_test.exs — the concrete medipim survivorship policy (gr-7yw), decomposed
# against SourcesRanker's verified semantics (gr-6y2 audit). The generic engine only sees the
# injected rank fn; every case here is a SourcesRanker behavior the policy must reproduce.
defmodule MedipimPolicyTest do
  use ExUnit.Case, async: true

  import Substrate, only: [claim: 5]

  @d1 ~D[2026-01-10]

  defp decide(entries, context, field \\ "name"),
    do: Survivorship.decide(field, entries, MedipimPolicy.rank_fn(context))

  defp entries(pairs) do
    for {{source, value}, i} <- Enum.with_index(pairs, 1),
        do: %{source: source, value: value, order: i}
  end

  describe "per-field scores" do
    test "the higher-scored org wins the field" do
      context = %{
        product_orgs: ["orgA", "orgB"],
        field_scores: %{"name" => %{"orgA" => 10, "orgB" => 5}}
      }

      decision = decide(entries([{"orgA", "Foo"}, {"orgB", "Bar"}]), context)
      assert %{value: "Foo", winner: "orgA", status: :resolved} = decision
    end

    test "scores are per field — the same org can win one field and lose another" do
      context = %{
        product_orgs: ["orgA", "orgB"],
        field_scores: %{"name" => %{"orgA" => 10}, "publicPrice" => %{"orgB" => 10}},
        source_order: ["orgA", "orgB"]
      }

      assert decide(entries([{"orgA", "Foo"}, {"orgB", "Bar"}]), context, "name").winner == "orgA"
      assert decide(entries([{"orgA", 1}, {"orgB", 2}]), context, "publicPrice").winner == "orgB"
    end

    test "sysId (org group) resolves BEFORE orgId" do
      context = %{
        product_orgs: ["orgA", "orgB"],
        sys_of: %{"orgA" => "sysX"},
        # orgA's own score says 1, but its org group says 20 — the group wins the lookup.
        field_scores: %{"name" => %{"sysX" => 20, "orgA" => 1, "orgB" => 10}}
      }

      assert decide(entries([{"orgA", "Foo"}, {"orgB", "Bar"}]), context).winner == "orgA"
    end
  end

  describe "the off-product −1 penalty" do
    test "a non-system source off the product loses to a default-0 source on it" do
      # orgOff scores 10 in the table, but it is not on the product: devalued to −1, so the
      # unscored (default-0) on-product orgB wins.
      context = %{
        product_orgs: ["orgB"],
        field_scores: %{"name" => %{"orgOff" => 10}}
      }

      decision = decide(entries([{"orgOff", "Foo"}, {"orgB", "Bar"}]), context)
      assert %{value: "Bar", winner: "orgB", status: :resolved} = decision
    end

    test "a system source is never penalized" do
      context = %{
        product_orgs: ["orgB"],
        system_sources: ["sys1"],
        field_scores: %{"name" => %{"sys1" => 10}}
      }

      assert decide(entries([{"sys1", "Foo"}, {"orgB", "Bar"}]), context).winner == "sys1"
    end

    test "labo orgs join the scoring set for region :be only" do
      base = %{product_orgs: [], labo_orgs: ["labo1"], source_order: ["labo1", "orgB"]}
      entries = entries([{"labo1", "Foo"}, {"orgB", "Bar"}])

      # BE: labo1 is on-product (score 0) and orgB off-product (−1) — labo1 wins.
      assert decide(entries, Map.put(base, :region, :be)).winner == "labo1"

      # FR: both are off-product (−1 each) — the array-order tie-break picks labo1, but for a
      # different reason; make orgB on-product to see the region gate flip the outcome.
      fr = base |> Map.put(:region, :fr) |> Map.put(:product_orgs, ["orgB"])
      assert decide(entries, fr).winner == "orgB"
    end

    test "orgs introduced by the in-flight delta still rank" do
      context = %{product_orgs: ["orgB"], delta_orgs: ["orgNew"], field_scores: %{"name" => %{"orgNew" => 5}}}

      assert decide(entries([{"orgNew", "Foo"}, {"orgB", "Bar"}]), context).winner == "orgNew"
    end
  end

  describe "the tie-break (DECISION 2026-08-13: replicate the legacy array-order pick)" do
    test "equal scores resolve deterministically by source-array order — never :needs_review" do
      context = %{product_orgs: ["orgA", "orgB"], source_order: ["orgB", "orgA"]}

      decision = decide(entries([{"orgA", "Foo"}, {"orgB", "Bar"}]), context)
      assert %{value: "Bar", winner: "orgB", status: :resolved} = decision
    end

    test "sources absent from the array still tie honestly when values differ" do
      # The legacy array cannot order sources it does not list; two unlisted equal-score
      # sources with different values stay :needs_review rather than picking arbitrarily.
      context = %{product_orgs: ["orgA", "orgB"]}

      assert decide(entries([{"orgA", "Foo"}, {"orgB", "Bar"}]), context).status == :needs_review
    end
  end

  describe "penalty_flips/2 — the flip-frequency measurement lever" do
    # A minimal whole-product fold: two sources disagree on a field; the off-product penalty is
    # the ONLY thing separating them, so toggling it flips the winner.
    defp rederivation do
      claims = [
        claim(:orgA, :identity, %{ref: "A", codes: [{:cnk, "0111"}]}, @d1, @d1),
        claim(:orgOff, :identity, %{ref: "B", codes: [{:cnk, "0111"}]}, @d1, @d1),
        claim(:orgA, :attribute, %{code: {:cnk, "0111"}, field: "name", value: "OnProduct"}, @d1, @d1),
        claim(:orgOff, :attribute, %{code: {:cnk, "0111"}, field: "name", value: "OffProduct"}, @d1, @d1),
        claim(:orgA, :grouping, %{code: {:cnk, "0111"}, product: "p1"}, @d1, @d1)
      ]

      stamped = claims |> Enum.with_index(1) |> Enum.map(fn {c, i} -> %{c | order: i} end)
      live = Substrate.current(stamped)
      {events, _ledgers} = Lanes.reconcile(live, MapSet.new(), Lanes.new_ledgers(), @d1)
      events = events |> Enum.with_index(length(stamped) + 1) |> Enum.map(fn {e, i} -> %{e | order: i} end)
      ledger = Enum.reduce(events, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1))
      %{log: stamped ++ events, ledger: ledger}
    end

    test "reports exactly the decisions the −1 band flips" do
      # orgOff outranks orgA on the score table but is NOT on the product.
      context = %{
        product_orgs: [:orgA],
        field_scores: %{"name" => %{orgOff: 10}},
        source_order: [:orgA, :orgOff]
      }

      report = MedipimPolicy.penalty_flips(rederivation(), context)

      assert [%{field: "name", with_penalty: with_p, without_penalty: without_p}] = report.flips
      assert with_p.winner == :orgA
      assert without_p.winner == :orgOff
      assert report.decisions >= 1
    end

    test "reports no flips when every source is on the product" do
      context = %{product_orgs: [:orgA, :orgOff], field_scores: %{"name" => %{orgOff: 10}}}

      assert MedipimPolicy.penalty_flips(rederivation(), context).flips == []
    end
  end

  test "the policy threads through GoldenRecords.project as a plain injected fn" do
    context = %{product_orgs: [:orgA], source_order: [:orgA, :orgOff]}

    claims = [
      claim(:orgA, :identity, %{ref: "A", codes: [{:cnk, "0111"}]}, @d1, @d1),
      claim(:orgA, :attribute, %{code: {:cnk, "0111"}, field: "name", value: "Foo"}, @d1, @d1),
      claim(:orgA, :grouping, %{code: {:cnk, "0111"}, product: "p1"}, @d1, @d1)
    ]

    stamped = claims |> Enum.with_index(1) |> Enum.map(fn {c, i} -> %{c | order: i} end)
    live = Substrate.current(stamped)
    {events, _} = Lanes.reconcile(live, MapSet.new(), Lanes.new_ledgers(), @d1)
    events = events |> Enum.with_index(length(stamped) + 1) |> Enum.map(fn {e, i} -> %{e | order: i} end)
    ledger = Enum.reduce(events, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1))

    %{records: [record]} =
      GoldenRecords.project(%{log: stamped ++ events, ledger: ledger}, MedipimPolicy.rank_fn(context))

    assert [%{attributes: attributes}] = record.variants
    assert {"name", %{value: "Foo", status: :resolved}} = List.keyfind(attributes, "name", 0)
  end
end
