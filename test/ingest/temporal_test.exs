# test/ingest/temporal_test.exs — ExUnit for the temporal pass (bead gr-qka, epic gr-nh0).
#
#   Run:  mix test
#
# Drives the real 422156 fixture through `Temporal.run/1` and asserts the HONEST temporal
# behaviour the fold actually produces — which is narrower than the design doc first imagined,
# for two structural reasons established during T2:
#
#   1. `ClaimMapping` emits one identity claim PER PERIOD of a listing's code set (gr-blb), so the
#      temporal pass now sees the intra-listing evolution it used to be blind to. 422156 mints
#      three keys over its history as barcodes arrive and move, rather than one flattened mint.
#      This replaced an earlier limitation, and with it the shape of the assertions below.
#   2. The reconcile NEVER auto-emits `IdentitiesMerged`. When a later code bridges two ESTABLISHED
#      keys, the gr-ose over-merge guard GATES it into a `ConflictFlagged` proposal (auto-merge
#      happens only via `Stewardship.approve_merge`). The synthetic cases below pin exactly that.
#
# Coverage: (1) real 422156 — single dated mint, before/after as-of variant counts, and the
# MONOTONICITY GUARD (as-of the latest known date == the v1 `GoldenRecords` snapshot — the core
# correctness anchor); (2) synthetic over-merge guard — a later bridge is FLAGGED, not merged;
# (3) synthetic MembersChanged — a later listing's new code extends the existing key; (4) boundary
# epoch→Date conversion + same-day collapse staying order-sequenced. Mirrors
# golden_records_test.exs conventions (terse synthetic-envelope helpers).

defmodule TemporalTest do
  use ExUnit.Case, async: true

  @fixture Path.join(__DIR__, "fixtures/medipim_be_422156.json")

  # ── helpers (same shape as golden_records_test.exs) ─────────────────────────
  defp envelope(entity, events) do
    {:ok, env} =
      HistoryEnvelope.from_map(%{
        "schema_version" => "1",
        "legacy_entity" => entity,
        "events" => events
      })

    env
  end

  defp id(source, scheme, code, at),
    do: %{
      "recorded_at" => at,
      "source" => source,
      "op" => "set",
      "kind" => "identity",
      "scheme" => scheme,
      "code" => code
    }

  defp attr(source, field, value, at),
    do: %{
      "recorded_at" => at,
      "source" => source,
      "op" => "set",
      "kind" => "attribute",
      "field" => field,
      "value" => value
    }

  # A Unix-epoch timestamp for a calendar `date` at `hour` UTC — the sub-day time exercises the
  # boundary day-collapse (epoch → `Date`) without changing the calendar date.
  defp epoch(%Date{} = date, hour),
    do: date |> DateTime.new!(Time.new!(hour, 0, 0)) |> DateTime.to_unix()

  # The surrogate keys of every projected variant, sorted — the projection's identity shape.
  defp variant_keys(records),
    do: records |> Enum.flat_map(& &1.variants) |> Enum.map(& &1.key) |> Enum.sort()

  # Assert-and-extract the single variant of an as-of projection.
  defp one_variant(records) do
    assert [variant] = Enum.flat_map(records, & &1.variants)
    variant
  end

  defp attribute(variant, name), do: variant.attributes |> Enum.into(%{}) |> Map.fetch!(name)

  # ── the real 422156 fixture — datable identity ──────────────────────────────
  describe "real entity 422156" do
    setup do
      {:ok, envs} = HistoryEnvelope.load(@fixture)
      envs = List.wrap(envs)
      %{envs: envs, result: Temporal.run(envs)}
    end

    test "the timeline shows identity EVOLVING — a CNK first, then barcodes arriving and moving",
         %{result: %{timeline: timeline}} do
      mints = for %Events.IdentityMinted{} = m <- timeline, do: m

      # Three keys over the entity's life. The old fold collapsed this to one mint because it kept
      # only each listing's final code set; periods make the evolution visible.
      assert length(mints) == 3
      [first | _] = mints

      # The CNK is what the entity was first known by, years before any barcode.
      assert %Date{} = first.recorded_at
      assert Date.compare(first.recorded_at, ~D[2019-01-01]) == :lt
      assert MapSet.member?(first.codes, Codes.canonicalize({:cnk, "3612173"}))

      minted = mints |> Enum.flat_map(&MapSet.to_list(&1.codes)) |> MapSet.new()
      assert MapSet.member?(minted, Codes.canonicalize({:gtin, "03282770049374"}))
      assert MapSet.member?(minted, Codes.canonicalize({:gtin, "03282770146004"}))
    end

    test "golden_as_of has no variant before the first mint, and the CNK's variant on it",
         %{result: %{log: log, timeline: timeline}} do
      [first | _] = for %Events.IdentityMinted{} = m <- timeline, do: m

      # Before any identity was recorded, the product has no resolvable variant.
      assert Temporal.golden_as_of(log, Date.add(first.recorded_at, -1)) == []

      assert [%{product: 422_156, variants: [variant]}] =
               Temporal.golden_as_of(log, first.recorded_at)

      assert variant.key == "SK_1"
      assert Codes.canonicalize({:cnk, "3612173"}) in variant.codes
    end

    test "MONOTONICITY GUARD: replay converges to v1 once the gated merges are approved",
         %{envs: envs, result: %{log: log}} do
      # The old guard asserted plain equality with v1. Replaying identity history broke it, and
      # correctly so: mid-history a barcode moves between listings, two keys exist, and when the
      # codes reconverge the over-merge guard REFUSES to fuse established keys on its own.
      #
      # The honest invariant is stronger than the old one. Replay loses nothing and invents
      # nothing: the only difference from v1 is the set of merges the engine declined to make
      # automatically, and approving exactly those recovers v1 precisely.
      today = log |> Enum.map(& &1.recorded_at) |> Enum.max(Date)
      v1 = GoldenRecords.from_envelopes(envs, 1).records

      proposed =
        for(%Events.ConflictFlagged{subject: {:merge, keys}} <- log, do: keys)
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.sort()

      assert proposed == ["SK_1", "SK_3"], "the divergence is one gated merge, nothing else"

      ledger = Enum.reduce(log, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1))
      next = log |> Enum.map(&(&1.order || 0)) |> Enum.max()

      approved =
        ledger.members
        |> Stewardship.approve_merge(proposed, :sam, today)
        |> Enum.with_index(next + 1)
        |> Enum.map(fn {event, i} -> %{event | order: i} end)

      assert Temporal.golden_as_of(log ++ approved, today) == strip_cnk(v1)
    end

    # golden_as_of is plain Catalog.project (no :cnk enrichment); strip v1's so the comparison is
    # of the golden record itself.
    defp strip_cnk(records) do
      Enum.map(records, fn r ->
        %{r | variants: Enum.map(r.variants, &Map.delete(&1, :cnk))}
      end)
    end
  end

  # ── synthetic — the over-merge guard holds TEMPORALLY ───────────────────────
  describe "over-merge guard (gr-ose), temporally" do
    # Two listings establish disjoint keys at d1; a third listing carries BOTH codes at d2, bridging
    # them. The engine refuses to silently merge two established identities — it FLAGS a proposal.
    defp gated_bridge do
      d1 = ~D[2024-01-01]
      d2 = ~D[2024-06-01]

      [
        envelope(100, [
          id("C", "gtin", "05000000000017", epoch(d1, 9)),
          id("D", "cnk", "1000000", epoch(d1, 9)),
          id("E", "gtin", "05000000000017", epoch(d2, 9)),
          id("E", "cnk", "1000000", epoch(d2, 9))
        ])
      ]
    end

    test "two disjoint identities mint at d1; the later bridge is FLAGGED, never auto-merged" do
      %{log: log, timeline: timeline} = Temporal.run(gated_bridge())

      mints = for %Events.IdentityMinted{key: k, recorded_at: r} <- timeline, do: {r, k}
      assert Enum.sort(mints) == [{~D[2024-01-01], "SK_1"}, {~D[2024-01-01], "SK_2"}]

      flags = for %Events.ConflictFlagged{subject: s, recorded_at: r} <- timeline, do: {r, s}
      assert flags == [{~D[2024-06-01], {:merge, ["SK_1", "SK_2"]}}]

      # Nothing else in the timeline, and emphatically NO auto-merge anywhere in the log.
      assert length(timeline) == 3
      refute Enum.any?(log, &match?(%Events.IdentitiesMerged{}, &1))

      # Both keys survive the bridge — the whole point of the guard.
      assert variant_keys(Temporal.golden_as_of(log, ~D[2024-01-01])) == ["SK_1", "SK_2"]
      assert variant_keys(Temporal.golden_as_of(log, ~D[2024-06-01])) == ["SK_1", "SK_2"]
    end
  end

  # ── synthetic — a later listing's new code extends the existing key ──────────
  describe "MembersChanged across dates" do
    test "a code introduced by a later listing extends the same key, dated when it arrived" do
      d1 = ~D[2024-02-01]
      d2 = ~D[2024-08-01]

      envs = [
        envelope(400, [
          id("H", "cnk", "4000000", epoch(d1, 9)),
          id("J", "cnk", "4000000", epoch(d2, 9)),
          id("J", "gtin", "05000000000017", epoch(d2, 9))
        ])
      ]

      %{log: log, timeline: timeline} = Temporal.run(envs)

      assert [
               %Events.IdentityMinted{key: "SK_1", recorded_at: ^d1},
               %Events.IdentityMembersChanged{key: "SK_1", codes: codes, recorded_at: ^d2}
             ] = timeline

      new_gtin = Codes.canonicalize({:gtin, "05000000000017"})
      assert MapSet.member?(codes, new_gtin)

      # Same key throughout; the new code is absent before it arrives and present after.
      before = one_variant(Temporal.golden_as_of(log, d1))
      later = one_variant(Temporal.golden_as_of(log, d2))
      assert before.key == "SK_1" and later.key == "SK_1"
      refute new_gtin in before.codes
      assert new_gtin in later.codes
    end
  end

  # ── boundary epoch→Date conversion ──────────────────────────────────────────
  describe "boundary conversion" do
    test "epoch timestamps convert to the calendar date (uni-temporal: valid_from == recorded_at)" do
      envs = [envelope(200, [id("S", "cnk", "2000000", epoch(~D[2024-03-14], 13))])]
      %{log: log} = Temporal.run(envs)

      claim = Enum.find(log, &match?(%Events.ClaimAsserted{kind: :identity}, &1))
      assert claim.recorded_at == ~D[2024-03-14]
      assert claim.valid_from == ~D[2024-03-14]
    end

    test "same-day deltas collapse to one date but stay order-sequenced; the later order wins" do
      day = ~D[2024-05-10]

      envs = [
        envelope(300, [
          id("S", "cnk", "3000000", epoch(day, 8)),
          attr("S", "color", "early", epoch(day, 8)),
          attr("S", "color", "late", epoch(day, 20))
        ])
      ]

      %{log: log} = Temporal.run(envs)

      colors =
        for %Events.ClaimAsserted{kind: :attribute, data: %{field: "color"}} = c <- log,
            do: {c.recorded_at, c.order, c.data.value}

      # Both same-day deltas survive in the log, on ONE date, with DISTINCT integer orders.
      assert [{^day, o1, "early"}, {^day, o2, "late"}] = Enum.sort_by(colors, &elem(&1, 1))
      assert is_integer(o1) and is_integer(o2) and o1 < o2

      # Survivorship picks the END-OF-DAY value (later order), not an intra-day midpoint — collapsing
      # to days cannot change a resolved value, because resolution keys off integer `order`, not Date.
      assert %{value: "late", status: :resolved} =
               attribute(one_variant(Temporal.golden_as_of(log, day)), "color")
    end
  end
end
