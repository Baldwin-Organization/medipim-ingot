# test/ingest/rederive_test.exs — ExUnit for the cluster+reconcile stage (bead gr-chq).
#
#   Run:  mix test
#
# Drives the real 422156 fixture end-to-end (claims → cluster → reconcile → ledger + log) and
# proves the re-derived log folds UNCHANGED through the engine's read layer. Plus synthetic cases
# that show re-derivation does real work beyond 422156's quiet convergence: two entities sharing a
# CNK MERGE into one key, and a shared (in-store) GTIN that rides along but never bridges two
# products. Mirrors claim_mapping_test.exs conventions (terse synthetic-envelope helpers).

alias GoldenRecord.{Events, Codes, Lanes, Api, PublicId}

defmodule RederivationTest do
  use ExUnit.Case, async: true

  @fixture Path.join(__DIR__, "fixtures/medipim_be_422156.json")

  # ── helpers (same shape as claim_mapping_test.exs) ──────────────────────────
  defp envelope(entity, events) do
    {:ok, env} =
      HistoryEnvelope.from_map(%{
        "schema_version" => "1",
        "legacy_entity" => entity,
        "events" => events
      })

    env
  end

  defp id(source, op, scheme, code, at),
    do: %{
      "recorded_at" => at,
      "source" => source,
      "op" => op,
      "kind" => "identity",
      "scheme" => scheme,
      "code" => code
    }

  defp identity_events(log), do: Enum.reject(log, &match?(%Events.ClaimAsserted{}, &1))

  # ── the real 422156 fixture ──────────────────────────────────────────────────
  describe "real entity 422156" do
    setup do
      {:ok, env} = HistoryEnvelope.load(@fixture)
      %{env: env}
    end

    test "all three listings re-derive to exactly ONE surrogate key", %{env: env} do
      result = Rederivation.run([env], 1)

      assert [_only] = result.clusters
      # the PRODUCT lane converges to one key; description/media lanes mint their own (gr-2a8)
      assert [{"SK_1", codes}] = Map.to_list(Lanes.partition_members(result.ledger.members).product)

      # the convergence the design calls out: CNK + the canonical GTIN of 03282770146004.
      assert MapSet.member?(codes, {:cnk, "3612173"})
      assert MapSet.member?(codes, Codes.canonicalize({:gtin, "03282770146004"}))
      assert MapSet.member?(codes, {:gtin, "03282770146004"})
    end

    test "the re-derived log folds cleanly through the engine", %{env: env} do
      %{log: log} = Rederivation.run([env], 1)

      # Api resolves any code on that key to SK_1, untouched.
      assert Api.resolve_key(log, {:cnk, "3612173"}) == "SK_1"
      assert Api.resolve_key(log, {:gtin, "03282770146004"}) == "SK_1"
      # an alias GTIN width canonicalizes to the same member and still resolves.
      assert Api.resolve_key(log, {:gtin, "3282770146004"}) == "SK_1"

      # CNK is identity-grade and must own exactly one key — no collisions.
      assert PublicId.collisions(:cnk, log) == []
    end

    test "identity events are stamped to continue after the max claim order", %{env: env} do
      %{log: log} = Rederivation.run([env], 1)

      max_claim_order =
        log |> Enum.filter(&match?(%Events.ClaimAsserted{}, &1)) |> Enum.map(& &1.order) |> Enum.max()

      ident = identity_events(log)

      assert Enum.all?(ident, &(&1.order > max_claim_order))
      # the change feed, cursored at the last claim, sees the freshly minted identity.
      assert Api.changes_since(log, max_claim_order) == ident
    end
  end

  # ── re-derivation does real work (synthetic) ─────────────────────────────────
  describe "through the engine" do
    test "two entities sharing a CNK MERGE into one surrogate key" do
      envs = [
        envelope(1, [id("A", "set", "cnk", "100", 10)]),
        envelope(2, [id("B", "set", "cnk", "100", 10)])
      ]

      result = Rederivation.run(envs, 1)

      assert [_one_cluster] = result.clusters
      assert [{"SK_1", _codes}] = Map.to_list(result.ledger.members)
      assert Api.resolve_key(result.log, {:cnk, "100"}) == "SK_1"
      assert Enum.count(identity_events(result.log), &match?(%Events.IdentityMinted{}, &1)) == 1
    end

    test "distinct products with no bridging code stay as separate keys" do
      envs = [
        envelope(10, [id("A", "set", "cnk", "111", 10)]),
        envelope(20, [id("B", "set", "cnk", "222", 10)])
      ]

      result = Rederivation.run(envs, 1)

      assert length(result.clusters) == 2
      assert Enum.sort(Map.keys(result.ledger.members)) == ["SK_1", "SK_2"]
      assert Api.resolve_key(result.log, {:cnk, "111"}) != Api.resolve_key(result.log, {:cnk, "222"})
    end

    test "a shared (in-store) GTIN rides on both products but never bridges them" do
      envs = [
        envelope(30, [id("A", "set", "cnk", "300", 10), id("A", "add", "gtin", "02000000000017", 11)]),
        envelope(40, [id("B", "set", "cnk", "400", 10), id("B", "add", "gtin", "02000000000017", 11)])
      ]

      built = ClaimMapping.build(envs)
      assert built.shared == MapSet.new([{:gtin, "02000000000017"}])

      result = Rederivation.from_claims(built, 1)

      # two keys despite the common code — the shared GTIN is carried, not fused on.
      assert length(result.clusters) == 2
      assert Enum.sort(Map.keys(result.ledger.members)) == ["SK_1", "SK_2"]

      for {_key, codes} <- result.ledger.members do
        assert MapSet.member?(codes, {:gtin, "02000000000017"})
      end
    end
  end
end
