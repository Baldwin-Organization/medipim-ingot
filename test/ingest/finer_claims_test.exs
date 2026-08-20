# test/ingest/finer_claims_test.exs — ExUnit for the finer-grained per-event fold (bead gr-apd).
#
#   Run:  mix test
#
# FinerClaims promotes the temporal_export.exs prototype into the supported ingest mode the
# Product API backfills with. The pivotal difference from the listing-collapse (`ClaimMapping` →
# `Temporal`): identity claims are emitted per RAW identity event at their true dates, so the real
# 422156 arc survives — org 44 is a distinct golden variant for years, and when its codes finally
# line up with the others, the over-merge guard raises a STANDING proposal instead of fusing.
# (The batch fold, with no prior keys to gate against, sees one cluster and one variant — the
# silent over-merge this whole design exists to prevent.)

alias GoldenRecord.{Events, Lanes, Substrate}

defmodule FinerClaimsTest do
  use ExUnit.Case, async: true

  @fixture Path.join(__DIR__, "fixtures/medipim_be_422156.json")

  defp envelope(entity, events) do
    {:ok, env} =
      HistoryEnvelope.from_map(%{
        "schema_version" => "1",
        "legacy_entity" => entity,
        "events" => events
      })

    env
  end

  defp id(source, scheme, code, at, op \\ "set"),
    do: %{
      "recorded_at" => at,
      "source" => source,
      "op" => op,
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

  defp epoch(%Date{} = date, hour \\ 9),
    do: date |> DateTime.new!(Time.new!(hour, 0, 0)) |> DateTime.to_unix()

  defp identity_claims(claims, ref),
    do: Enum.filter(claims, &(&1.kind == :identity and &1.data.ref == ref))

  # ── per-event granularity ────────────────────────────────────────────────────
  describe "build/1 — per-event identity snapshots" do
    test "each identity delta emits a dated snapshot of the ACCUMULATED code-set" do
      env =
        envelope(900, [
          id("A", "cnk", "1000000", epoch(~D[2020-01-01])),
          id("A", "eanGtin13", "5012345678900", epoch(~D[2021-06-01])),
          id("A", "eanGtin13", "4012345678901", epoch(~D[2022-03-01]))
        ])

      %{claims: claims} = FinerClaims.build([env])
      snaps = identity_claims(claims, "900:A")

      assert Enum.map(snaps, & &1.recorded_at) == [~D[2020-01-01], ~D[2021-06-01], ~D[2022-03-01]]

      assert Enum.map(snaps, & &1.data.codes) == [
               [{:cnk, "1000000"}],
               [{:cnk, "1000000"}, {:gtin, "05012345678900"}],
               [{:cnk, "1000000"}, {:gtin, "04012345678901"}]
             ]
    end

    test "a delta that doesn't change the canonical code-set is deduplicated; pre-identity empties are skipped" do
      env =
        envelope(901, [
          # remove before anything exists -> empty -> skipped
          id("A", "ean", "5012345678900", epoch(~D[2020-01-01]), "remove"),
          id("A", "cnk", "1000000", epoch(~D[2020-02-01])),
          # re-setting the SAME value -> same canonical set -> deduplicated
          id("A", "cnk", "1000000", epoch(~D[2020-03-01]))
        ])

      %{claims: claims} = FinerClaims.build([env])
      assert [snap] = identity_claims(claims, "901:A")
      assert snap.recorded_at == ~D[2020-02-01]
    end

    test "a full withdrawal emits an empty identity snapshot" do
      env =
        envelope(908, [
          id("A", "cnk", "1000000", epoch(~D[2020-01-01])),
          id("A", "cnk", "1000000", epoch(~D[2021-01-01]), "remove")
        ])

      %{claims: claims} = FinerClaims.build([env])

      assert [
               %Events.ClaimAsserted{data: %{codes: [{:cnk, "1000000"}]}, recorded_at: ~D[2020-01-01]},
               %Events.ClaimAsserted{data: %{codes: []}, recorded_at: ~D[2021-01-01]}
             ] = identity_claims(claims, "908:A")
    end

    test "claims are Date-typed throughout and order-stamped chronologically" do
      env =
        envelope(902, [
          id("B", "cnk", "2000000", epoch(~D[2021-01-01])),
          id("A", "cnk", "1000000", epoch(~D[2020-01-01])),
          attr("A", "name", "Sun cream", epoch(~D[2020-05-01]))
        ])

      %{claims: claims} = FinerClaims.build([env])
      assert Enum.all?(claims, &match?(%Date{}, &1.recorded_at))
      assert Enum.map(claims, & &1.order) == Enum.sort(Enum.map(claims, & &1.order))

      dates = Enum.map(claims, & &1.recorded_at)
      assert dates == Enum.sort(dates, Date)
    end
  end

  # ── anchoring follows the evolving identity ──────────────────────────────────
  describe "build/1 — attribute anchoring" do
    test "an attribute anchors to the listing's primary AS OF that moment, not the final one" do
      env =
        envelope(903, [
          id("A", "eanGtin13", "5012345678900", epoch(~D[2020-01-01])),
          attr("A", "name", "Old name", epoch(~D[2020-06-01])),
          # the CNK arrives later and becomes the (final) primary
          id("A", "cnk", "1000000", epoch(~D[2021-01-01])),
          attr("A", "name", "New name", epoch(~D[2021-06-01]))
        ])

      %{claims: claims} = FinerClaims.build([env])
      [old, new] = claims |> Enum.filter(&(&1.kind == :attribute)) |> Enum.sort_by(& &1.order)

      assert old.data.code == {:gtin, "05012345678900"}
      assert new.data.code == {:cnk, "1000000"}
    end

    test ~s(a one-element list value unwraps exactly like the batch fold: ["human"] == "human") do
      env =
        envelope(905, [
          id("A", "cnk", "1000000", epoch(~D[2020-01-01])),
          attr("A", "allowedSpecies", ["human"], epoch(~D[2020-06-01]))
        ])

      %{claims: claims} = FinerClaims.build([env])
      assert [a] = Enum.filter(claims, &(&1.kind == :attribute))
      assert a.data.value == "human"
    end

    test "an attribute BEFORE any identity falls back to the listing's final primary" do
      env =
        envelope(904, [
          attr("A", "name", "Early bird", epoch(~D[2019-01-01])),
          id("A", "cnk", "1000000", epoch(~D[2020-01-01]))
        ])

      %{claims: claims} = FinerClaims.build([env])
      assert [a] = Enum.filter(claims, &(&1.kind == :attribute))
      assert a.data.code == {:cnk, "1000000"}
    end
  end

  # ── fold_forward: threading a prior ledger ───────────────────────────────────
  describe "fold_forward/4" do
    test "a fresh fold mints once per distinct identity; keys stay stable across dates" do
      env =
        envelope(905, [
          id("A", "cnk", "1000000", epoch(~D[2020-01-01])),
          id("A", "eanGtin13", "5012345678900", epoch(~D[2021-01-01]))
        ])

      %{claims: claims, shared: shared} = FinerClaims.build([env])
      %{events: events, ledger: ledger} = FinerClaims.fold_forward(claims, shared)

      assert [%Events.IdentityMinted{key: key}, %Events.IdentityMembersChanged{key: key}] = events
      assert Map.keys(ledger.members) == [key]
    end

    test "continuing from an existing ledger reuses keys instead of re-minting (the live path)" do
      env1 = envelope(906, [id("A", "cnk", "1000000", epoch(~D[2020-01-01]))])
      %{claims: c1, shared: s1} = FinerClaims.build([env1])
      %{events: e1, ledger: ledger} = FinerClaims.fold_forward(c1, s1)
      assert [%Events.IdentityMinted{key: key}] = e1

      # the same listing grows a code later — fold only the NEW date, threading the ledger
      env2 =
        envelope(906, [
          id("A", "cnk", "1000000", epoch(~D[2020-01-01])),
          id("A", "eanGtin13", "5012345678900", epoch(~D[2022-01-01]))
        ])

      %{claims: c2, shared: s2} = FinerClaims.build([env2])
      %{events: e2, ledger: ledger2} = FinerClaims.fold_forward(c2, s2, ledger, [~D[2022-01-01]])

      assert [%Events.IdentityMembersChanged{key: ^key}] = e2
      assert ledger2.members[key] == MapSet.new([{:cnk, "1000000"}, {:gtin, "05012345678900"}])
    end

    test "a late bridge between two ESTABLISHED keys is flagged, never merged" do
      base = [
        id("A", "cnk", "1000000", epoch(~D[2020-01-01])),
        id("B", "eanGtin13", "5012345678900", epoch(~D[2020-01-01])),
        # B later picks up A's CNK — the bridge
        id("B", "cnk", "1000000", epoch(~D[2023-01-01]))
      ]

      %{claims: claims, shared: shared} = FinerClaims.build([envelope(907, base)])
      %{events: events, ledger: ledger} = FinerClaims.fold_forward(claims, shared)

      assert Enum.any?(events, &match?(%Events.ConflictFlagged{subject: {:merge, _}}, &1))
      refute Enum.any?(events, &match?(%Events.IdentitiesMerged{}, &1))
      assert map_size(ledger.members) == 2
    end

    test "a listing withdrawn to empty retracts its key" do
      env =
        envelope(909, [
          id("A", "cnk", "1000000", epoch(~D[2020-01-01])),
          id("A", "cnk", "1000000", epoch(~D[2021-01-01]), "remove")
        ])

      %{claims: claims, shared: shared} = FinerClaims.build([env])
      %{events: events, ledger: ledger} = FinerClaims.fold_forward(claims, shared)

      assert [
               %Events.IdentityMinted{key: key, codes: codes, recorded_at: ~D[2020-01-01]},
               %Events.IdentityRetracted{
                 key: retracted_key,
                 codes: retracted_codes,
                 recorded_at: ~D[2021-01-01]
               }
             ] = events

      assert retracted_key == key
      assert retracted_codes == codes

      assert ledger.members == %{}
    end
  end

  # ── the real 422156 fixture: the arc the listing-collapse loses ──────────────
  describe "real entity 422156" do
    setup do
      %{env: HistoryEnvelope.load!(@fixture)}
    end

    test "recovers the divergence arc: more than one mint, and 2 live variants at the end", %{env: env} do
      %{timeline: timeline, ledger: ledger} = FinerClaims.run([env])

      mints = Enum.filter(timeline, &match?(%Events.IdentityMinted{}, &1))
      assert length(mints) > 1, "the finer fold must recover org 44's distinct identity"

      # the convergence is GATED: a standing merge proposal, no auto-merge
      assert Enum.any?(timeline, &match?(%Events.ConflictFlagged{subject: {:merge, _}}, &1))
      refute Enum.any?(timeline, &match?(%Events.IdentitiesMerged{}, &1))

      # live keys at the end: the two established identities survive (plus possibly retired keys)
      live = live_keys(ledger, env)
      assert length(live) == 2
    end

    test "the honest difference from the batch fold: v1 sees ONE variant, finer sees TWO", %{env: env} do
      %{records: records} = GoldenRecords.from_envelopes([env], env.last_touched_at)
      v1_variants = Enum.flat_map(records, & &1.variants)

      assert length(v1_variants) == 1

      %{ledger: ledger} = FinerClaims.run([env])
      assert length(live_keys(ledger, env)) == 2
    end

    test "golden_as_of before the convergence shows the codes known THEN", %{env: env} do
      %{log: log, timeline: timeline} = FinerClaims.run([env])
      [first_mint | _] = for %Events.IdentityMinted{} = m <- timeline, do: m

      golden = Temporal.golden_as_of(log, first_mint.recorded_at)
      keys = golden |> Enum.flat_map(& &1.variants) |> Enum.map(& &1.key)
      assert first_mint.key in keys
    end

    test "preserves media and description lane records from the backfill", %{env: env} do
      %{log: log, ledger: ledger} = FinerClaims.run([env])
      lanes = Lanes.partition_members(ledger.members)

      assert map_size(lanes.description) > 0
      assert map_size(lanes.media) > 0

      assert Enum.any?(log, &match?(%Events.ClaimAsserted{kind: :edge, data: %{relation: :describes}}, &1))
      assert Enum.any?(log, &match?(%Events.ClaimAsserted{kind: :edge, data: %{relation: :depicts}}, &1))
    end
  end

  # Keys whose membership still overlaps a code some source CURRENTLY claims — the live keys
  # (dead-barcode orphans excluded), mirroring the export prototype's aliveness rule.
  defp live_keys(ledger, env) do
    %{claims: claims} = FinerClaims.build([env])

    live_codes =
      claims
      |> Enum.filter(&(&1.kind == :identity))
      |> Substrate.current()
      |> Enum.flat_map(& &1.data.codes)
      |> MapSet.new()

    for {key, codes} <- ledger.members,
        Lanes.lane_of_key(key) == :product,
        not MapSet.disjoint?(codes, live_codes),
        do: key
  end
end
