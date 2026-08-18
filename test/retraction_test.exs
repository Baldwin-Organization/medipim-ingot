# test/retraction_test.exs — retraction: an integrator withdraws a previously asserted listing.
#
#   Run:  mix test test/retraction_test.exs
#
# Exercises the retraction path end-to-end at the engine level (no API, no database): five
# products imported via canonical claims, then one retracted by submitting an identity claim
# with codes: []. The reconciler detects the vanished key and emits IdentityRetracted.

alias GoldenRecord.{Events, Substrate, Cluster, IdentityLedger, Stewardship}

defmodule RetractionTest do
  use ExUnit.Case, async: true

  # ── helpers ──────────────────────────────────────────────────────────────

  defp identity(source, ref, codes, at) do
    Substrate.claim(source, :identity, %{ref: ref, codes: codes}, at, at)
  end

  defp attribute(source, code, field, value, at) do
    Substrate.claim(source, :attribute, %{code: code, field: field, value: value}, at, at)
  end

  defp reconcile(claims, ledger, at) do
    live = Substrate.current(claims)
    clusters = Cluster.variants(live)
    IdentityLedger.decide(ledger, {:reconcile, clusters, at})
  end

  defp apply_events(ledger, events) do
    Enum.reduce(events, ledger, &IdentityLedger.evolve(&2, &1))
  end

  defp key_for_code(ledger, code) do
    Enum.find_value(ledger.members, fn {key, codes} ->
      if MapSet.member?(codes, code), do: key
    end)
  end

  defp stamp(claims) do
    claims
    |> Enum.with_index(1)
    |> Enum.map(fn {c, i} -> %{c | order: i} end)
  end

  # ── 5 products, retract one ──────────────────────────────────────────────

  @retracted_ean {:gtin, "03282770146004"}

  describe "5 products, retract one" do
    setup do
      eans = [
        "05012345678900",
        "04006381333931",
        "03282770146004",
        "08710398000118",
        "04009750602461"
      ]

      initial_claims =
        for {ean, i} <- Enum.with_index(eans, 1) do
          identity("integrator", "P-#{i}", [{:gtin, ean}], 10)
        end
        |> stamp()

      round1_events = reconcile(initial_claims, IdentityLedger.new(), 10)
      ledger = apply_events(IdentityLedger.new(), round1_events)
      retracted_key = key_for_code(ledger, @retracted_ean)

      %{
        initial_claims: initial_claims,
        eans: eans,
        ledger: ledger,
        round1_events: round1_events,
        retracted_key: retracted_key
      }
    end

    test "round 1: all five products mint a surrogate key", %{round1_events: events} do
      minted = Enum.filter(events, &match?(%Events.IdentityMinted{}, &1))
      assert length(minted) == 5
    end

    test "round 2: retracting P-3 emits IdentityRetracted for its key", ctx do
      retraction = identity("integrator", "P-3", [], 20)
      all_claims = ctx.initial_claims ++ stamp_from([retraction], ctx.initial_claims)

      round2_events = reconcile(all_claims, ctx.ledger, 20)

      retracted = Enum.filter(round2_events, &match?(%Events.IdentityRetracted{}, &1))
      assert [%Events.IdentityRetracted{key: key, codes: codes}] = retracted
      assert key == ctx.retracted_key
      assert MapSet.member?(codes, @retracted_ean)
    end

    test "round 2: the other four keys are stable (no churn)", ctx do
      retraction = identity("integrator", "P-3", [], 20)
      all_claims = ctx.initial_claims ++ stamp_from([retraction], ctx.initial_claims)

      round2_events = reconcile(all_claims, ctx.ledger, 20)

      assert Enum.filter(round2_events, &match?(%Events.IdentityMinted{}, &1)) == []
      assert Enum.filter(round2_events, &match?(%Events.IdentityMembersChanged{}, &1)) == []
      assert Enum.filter(round2_events, &match?(%Events.IdentitySplit{}, &1)) == []
    end

    test "round 2: the retracted key is removed from the ledger", ctx do
      retraction = identity("integrator", "P-3", [], 20)
      all_claims = ctx.initial_claims ++ stamp_from([retraction], ctx.initial_claims)

      round2_events = reconcile(all_claims, ctx.ledger, 20)
      ledger2 = apply_events(ctx.ledger, round2_events)

      refute Map.has_key?(ledger2.members, ctx.retracted_key)
      assert map_size(ledger2.members) == 4
    end

    test "attributes anchored to the retracted code are orphaned", ctx do
      attr = attribute("integrator", @retracted_ean, "name:fr", "Crème solaire", 10)
      retraction = identity("integrator", "P-3", [], 20)

      all_claims = ctx.initial_claims ++ stamp_from([attr, retraction], ctx.initial_claims)

      round2_events = reconcile(all_claims, ctx.ledger, 20)
      ledger2 = apply_events(ctx.ledger, round2_events)

      live = Substrate.current(all_claims)
      attrs = Enum.filter(live, &(&1.kind == :attribute))

      assert [orphan] = attrs
      assert orphan.data.code == @retracted_ean

      owned_codes = ledger2.members |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)
      refute MapSet.member?(owned_codes, @retracted_ean)
    end
  end

  # ── edge cases ──────────────────────────────────────────────────────────

  describe "retraction edge cases" do
    test "retracting one listing when another source still asserts the same code — key survives" do
      claims =
        [
          identity("source_A", "P-1", [{:cnk, "100"}], 10),
          identity("source_B", "P-2", [{:cnk, "100"}], 10)
        ]
        |> stamp()

      round1_events = reconcile(claims, IdentityLedger.new(), 10)
      ledger = apply_events(IdentityLedger.new(), round1_events)

      assert [%Events.IdentityMinted{key: "SK_1"}] = round1_events

      retraction = identity("source_A", "P-1", [], 20)
      all_claims = claims ++ stamp_from([retraction], claims)

      round2_events = reconcile(all_claims, ledger, 20)
      retracted = Enum.filter(round2_events, &match?(%Events.IdentityRetracted{}, &1))

      assert retracted == []
      assert Map.has_key?(apply_events(ledger, round2_events).members, "SK_1")
    end

    test "surviving key drops exclusive codes from the retracted listing" do
      claims =
        [
          identity("source_A", "P-1", [{:cnk, "100"}, {:gtin, "05012345678900"}], 10),
          identity("source_B", "P-2", [{:cnk, "100"}], 10)
        ]
        |> stamp()

      round1_events = reconcile(claims, IdentityLedger.new(), 10)
      ledger = apply_events(IdentityLedger.new(), round1_events)

      assert ledger.members["SK_1"] == MapSet.new([{:cnk, "100"}, {:gtin, "05012345678900"}])

      retraction = identity("source_A", "P-1", [], 20)
      all_claims = claims ++ stamp_from([retraction], claims)

      round2_events = reconcile(all_claims, ledger, 20)
      ledger2 = apply_events(ledger, round2_events)

      assert Map.has_key?(ledger2.members, "SK_1")
      assert ledger2.members["SK_1"] == MapSet.new([{:cnk, "100"}])
      refute MapSet.member?(ledger2.members["SK_1"], {:gtin, "05012345678900"})
    end

    test "retracting the sole listing on a key DOES retract it" do
      claims = [identity("source_A", "P-1", [{:cnk, "100"}], 10)] |> stamp()

      round1_events = reconcile(claims, IdentityLedger.new(), 10)
      ledger = apply_events(IdentityLedger.new(), round1_events)

      retraction = identity("source_A", "P-1", [], 20)
      all_claims = claims ++ stamp_from([retraction], claims)

      round2_events = reconcile(all_claims, ledger, 20)
      assert [%Events.IdentityRetracted{key: "SK_1", codes: codes}] = round2_events
      assert MapSet.member?(codes, {:cnk, "100"})
    end
  end

  # ── validator accepts empty codes ───────────────────────────────────────

  describe "validator" do
    test "an identity claim with codes: [] passes validation" do
      claim = %{
        "kind" => "identity",
        "source" => "integrator",
        "ref" => "P-3",
        "codes" => []
      }

      assert {:ok, _warnings} = ClaimsValidator.validate([claim])
    end

    test "the canonical-claims builder handles empty codes" do
      claim = %{
        "kind" => "identity",
        "source" => "integrator",
        "ref" => "P-3",
        "codes" => []
      }

      assert {:ok, [engine_claim]} = CanonicalClaims.to_engine([claim], recorded_at: ~D[2026-06-25])
      assert engine_claim.kind == :identity
      assert engine_claim.data.codes == []
    end
  end

  # ── source withdrawal flag ───────────────────────────────────────────────

  describe "source withdrawal flag" do
    test "two sources, one retracts, key survives -> flag emitted naming the withdrawn source" do
      claims =
        [
          identity("source_A", "P-1", [{:cnk, "100"}], 10),
          identity("source_B", "P-2", [{:cnk, "100"}], 10)
        ]
        |> stamp()

      round1_events = reconcile(claims, IdentityLedger.new(), 10)
      ledger = apply_events(IdentityLedger.new(), round1_events)

      old_live = Substrate.current(claims)

      retraction = identity("source_A", "P-1", [], 20)
      all_claims = claims ++ stamp_from([retraction], claims)

      round2_events = reconcile(all_claims, ledger, 20)
      ledger2 = apply_events(ledger, round2_events)
      new_live = Substrate.current(all_claims)

      flags = Stewardship.detect_withdrawals(old_live, new_live, ledger2.members, 20)

      assert [%Events.ConflictFlagged{subject: {:source_withdrew, "SK_1"}} = flag] = flags
      assert "source_A" in Enum.map(flag.candidates, & &1.source)
    end

    test "sole source retracts, key vanishes -> NO withdrawal flag (IdentityRetracted handles it)" do
      claims = [identity("source_A", "P-1", [{:cnk, "100"}], 10)] |> stamp()

      round1_events = reconcile(claims, IdentityLedger.new(), 10)
      ledger = apply_events(IdentityLedger.new(), round1_events)

      old_live = Substrate.current(claims)

      retraction = identity("source_A", "P-1", [], 20)
      all_claims = claims ++ stamp_from([retraction], claims)

      round2_events = reconcile(all_claims, ledger, 20)
      ledger2 = apply_events(ledger, round2_events)
      new_live = Substrate.current(all_claims)

      flags = Stewardship.detect_withdrawals(old_live, new_live, ledger2.members, 20)

      assert flags == []
    end

    test "no retraction -> no flag" do
      claims =
        [
          identity("source_A", "P-1", [{:cnk, "100"}], 10),
          identity("source_B", "P-2", [{:cnk, "100"}], 10)
        ]
        |> stamp()

      round1_events = reconcile(claims, IdentityLedger.new(), 10)
      ledger = apply_events(IdentityLedger.new(), round1_events)
      live = Substrate.current(claims)

      flags = Stewardship.detect_withdrawals(live, live, ledger.members, 10)

      assert flags == []
    end
  end

  # ── stamp helpers ───────────────────────────────────────────────────────

  defp stamp_from(claims, prior) do
    base = length(prior)

    claims
    |> Enum.with_index(base + 1)
    |> Enum.map(fn {c, i} -> %{c | order: i} end)
  end
end
