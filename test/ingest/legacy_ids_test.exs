# test/ingest/legacy_ids_test.exs — legacy-ID continuity (bead gr-twa).
#
# The backwards-compatibility contract: every golden key answers to a legacy medipim ID — inherited
# from grouping evidence for backfilled keys, freshly allocated above the max for new ones — and a
# legacy id keeps resolving across merges (to the survivor) and splits (the kept key).

alias GoldenRecord.{Events, Substrate, Cluster, IdentityLedger, Stewardship}

defmodule LegacyIdsTest do
  use ExUnit.Case, async: true
  import Substrate, only: [claim: 5]

  @d1 ~D[2026-01-10]
  @d2 ~D[2026-02-01]

  defp stamp(entries, start),
    do:
      {entries |> Enum.with_index(start) |> Enum.map(fn {e, i} -> %{e | order: i} end),
       start + length(entries)}

  defp grouping(source, code, entity, d \\ @d1),
    do: claim(source, :grouping, %{code: code, product: entity}, d, d)

  describe "decide/4 — inheritance from grouping evidence" do
    test "a backfilled key inherits the legacy entity its codes vote for" do
      claims = [grouping(:a, {:cnk, "111"}, 422_156), grouping(:b, {:gtin, "222"}, 422_156)]
      members = %{"SK_1" => MapSet.new([{:cnk, "111"}, {:gtin, "222"}])}

      assert [%Events.LegacyIdAssigned{key: "SK_1", legacy_id: 422_156}] =
               LegacyIds.decide(members, claims, %{}, @d1)
    end

    test "a key spanning two entities takes the dominant vote; a tie breaks to the LOWEST id" do
      claims = [
        grouping(:a, {:cnk, "111"}, 100),
        grouping(:b, {:cnk, "111"}, 100),
        grouping(:c, {:gtin, "222"}, 200)
      ]

      members = %{"SK_1" => MapSet.new([{:cnk, "111"}, {:gtin, "222"}])}
      assert [%{legacy_id: 100}] = LegacyIds.decide(members, claims, %{}, @d1)

      tie = [grouping(:a, {:cnk, "111"}, 300), grouping(:b, {:gtin, "222"}, 200)]
      assert [%{legacy_id: 200}] = LegacyIds.decide(members, tie, %{}, @d1)
    end

    test "two keys splitting one legacy entity: one inherits, the other re-allocates (no duplicate ids)" do
      claims = [grouping(:a, {:cnk, "111"}, 500), grouping(:b, {:gtin, "222"}, 500)]

      members = %{
        "SK_1" => MapSet.new([{:cnk, "111"}]),
        "SK_2" => MapSet.new([{:gtin, "222"}])
      }

      events = LegacyIds.decide(members, claims, %{}, @d1)
      ids = Enum.map(events, & &1.legacy_id)
      assert 500 in ids
      assert length(Enum.uniq(ids)) == 2
      assert Enum.max(ids) > 500
    end

    test "re-allocation on duplicate inheritance clears the GLOBAL floor, not just this batch's" do
      claims = [grouping(:a, {:cnk, "111"}, 5), grouping(:b, {:gtin, "222"}, 5)]

      members = %{
        "SK_2" => MapSet.new([{:cnk, "111"}]),
        "SK_3" => MapSet.new([{:gtin, "222"}])
      }

      events = LegacyIds.decide(members, claims, %{"SK_9" => 30}, @d1)
      by_key = Map.new(events, &{&1.key, &1.legacy_id})
      assert by_key["SK_2"] == 5
      assert by_key["SK_3"] == 31
    end
  end

  describe "decide/4 — allocation for new products" do
    test "a key with no legacy evidence allocates ABOVE every id ever seen" do
      claims = [grouping(:a, {:cnk, "111"}, 422_156)]

      members = %{
        "SK_1" => MapSet.new([{:cnk, "111"}]),
        "SK_2" => MapSet.new([{:gtin, "999"}])
      }

      events = LegacyIds.decide(members, claims, %{}, @d1)
      by_key = Map.new(events, &{&1.key, &1.legacy_id})
      assert by_key["SK_1"] == 422_156
      assert by_key["SK_2"] == 422_157
    end

    test "allocation also clears previously ASSIGNED ids (post-backfill products)" do
      members = %{"SK_9" => MapSet.new([{:gtin, "777"}])}
      assert [%{legacy_id: 600_001}] = LegacyIds.decide(members, [], %{"SK_1" => 600_000}, @d1)
    end

    test "idempotent: nothing to assign -> no events" do
      members = %{"SK_1" => MapSet.new([{:cnk, "111"}])}
      assert LegacyIds.decide(members, [], %{"SK_1" => 422_156}, @d2) == []
    end
  end

  describe "fold/1 + resolve/2 — continuity across merges and splits" do
    # Build a real mini-log: two products, assigned ids, then a steward merge / split.
    defp base_log do
      claims = [
        claim(:a, :identity, %{ref: "A", codes: [{:cnk, "111"}]}, @d1, @d1),
        claim(:b, :identity, %{ref: "B", codes: [{:gtin, "222"}]}, @d1, @d1)
      ]

      {claims, o} = stamp(claims, 0)

      live = Substrate.current(claims)
      events = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, Cluster.variants(live), @d1})
      {events, o} = stamp(events, o)
      ledger = Enum.reduce(events, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1))

      {assigns, o} = LegacyIds.decide(ledger.members, claims, %{}, @d1) |> stamp(o)

      {claims ++ events ++ assigns, ledger, o}
    end

    test "an assigned id resolves to its key; unknown ids resolve to nil" do
      {log, ledger, _} = base_log()
      [k1, k2] = ledger.members |> Map.keys() |> Enum.sort()
      ids = LegacyIds.fold(log)

      assert LegacyIds.resolve(log, ids[k1]) == %{key: k1, status: :active}
      assert LegacyIds.resolve(log, ids[k2]) == %{key: k2, status: :active}
      assert LegacyIds.resolve(log, 999_999) == nil
    end

    test "after a merge, the ABSORBED key's legacy id resolves to the SURVIVOR" do
      {log, ledger, o} = base_log()
      [k1, k2] = ledger.members |> Map.keys() |> Enum.sort()
      ids = LegacyIds.fold(log)

      {merge, _} = Stewardship.approve_merge(ledger.members, [k1, k2], :sam, @d2) |> stamp(o)
      log = log ++ merge

      assert %{key: ^k1, status: :active} = LegacyIds.resolve(log, ids[k2])
      assert %{key: ^k1, status: :active} = LegacyIds.resolve(log, ids[k1])
      # the survivor's own id is unchanged
      assert LegacyIds.legacy_id(log, k1) == ids[k1]
    end

    test "after a split, the kept key keeps its id and the carved key allocates a fresh one" do
      {log, ledger, o} = base_log()
      [k1, k2] = ledger.members |> Map.keys() |> Enum.sort()
      ids = LegacyIds.fold(log)

      {merge, o} = Stewardship.approve_merge(ledger.members, [k1, k2], :sam, @d2) |> stamp(o)
      ledger = Enum.reduce(merge, ledger, &IdentityLedger.evolve(&2, &1))

      {split, o} = Stewardship.split(ledger, k1, [[{:gtin, "222"}]], :sam, @d2) |> stamp(o)
      ledger = Enum.reduce(split, ledger, &IdentityLedger.evolve(&2, &1))
      log = log ++ merge ++ split

      [carved] = Map.keys(ledger.members) -- [k1]
      claims = Enum.filter(log, &match?(%Events.ClaimAsserted{}, &1))

      {assigns, _} = LegacyIds.decide(ledger.members, claims, LegacyIds.fold(log), @d2) |> stamp(o)
      log = log ++ assigns

      # the kept key still answers to its original id
      assert %{key: ^k1} = LegacyIds.resolve(log, ids[k1])
      # the carved key allocated a FRESH id, above everything ever assigned
      carved_id = LegacyIds.legacy_id(log, carved)
      assert carved_id > Enum.max(Map.values(ids))
    end
  end
end
