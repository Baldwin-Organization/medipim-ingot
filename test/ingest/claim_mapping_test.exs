# test/ingest/claim_mapping_test.exs — ExUnit for the claim mapper (bead gr-beo).
#
#   Run:  mix test
#
# Covers the fold semantics (set/add/remove/delete/clear), canonicalize+partition (shared set),
# and the claim shapes — against synthetic envelopes AND the real 422156 fixture, driven all the
# way through the engine (cluster + reconcile) to prove the loop end-to-end. Modules compiled
# from lib/; ExUnit starts in test/test_helper.exs.

alias GoldenRecord.{Events, Lanes, Substrate, Cluster, IdentityLedger, Stewardship}

defmodule ClaimMappingTest do
  use ExUnit.Case, async: true

  @fixture Path.join(__DIR__, "fixtures/medipim_be_422156.json")

  # ── helpers ──────────────────────────────────────────────────────────────
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

  # product-lane clusters — the description/media lanes reconcile separately (gr-2a8)
  defp clusters(%{claims: claims, shared: shared}),
    do: Cluster.variants(Lanes.identity_claims(Substrate.current(claims), :product), shared)

  # ── fold semantics ─────────────────────────────────────────────────────────
  describe "fold" do
    test "set replaces a single-valued scheme" do
      env = envelope(1, [id("A", "set", "cnk", "111", 10), id("A", "set", "cnk", "222", 20)])
      assert ClaimMapping.listings([env]) == %{{1, "A"} => MapSet.new([{:cnk, "222"}])}
    end

    test "add accumulates, remove deletes one" do
      env =
        envelope(1, [
          id("A", "add", "ean", "5012345678900", 10),
          id("A", "add", "ean", "4006381333931", 20),
          id("A", "remove", "ean", "5012345678900", 30)
        ])

      assert ClaimMapping.listings([env]) == %{{1, "A"} => MapSet.new([{:gtin, "04006381333931"}])}
    end

    test "delete (op-4) drops the whole scheme entry" do
      env =
        envelope(1, [
          id("A", "set", "eanGtin13", "5012345678900", 10),
          id("A", "delete", "eanGtin13", "A", 20)
        ])

      assert ClaimMapping.listings([env]) == %{}
    end

    test "set-null clears the code" do
      env =
        envelope(1, [id("A", "set", "eanGtin14", "05012345678900", 10), id("A", "set", "eanGtin14", nil, 20)])

      assert ClaimMapping.listings([env]) == %{}
    end

    test "canonicalize merges an EAN-13 and its GTIN-14 form into one code" do
      env =
        envelope(1, [
          id("A", "add", "ean", "5012345678900", 10),
          id("A", "set", "eanGtin14", "05012345678900", 20)
        ])

      assert ClaimMapping.listings([env]) == %{{1, "A"} => MapSet.new([{:gtin, "05012345678900"}])}
    end

    # PR #3 review (CodeRabbit): an unrecognised scheme must not String.to_atom/1 (atom-leak).
    test "an unrecognised identity scheme stays a string — no atom created, no crash" do
      env = envelope(1, [id("A", "set", "mysteryScheme", "XYZ", 10)])
      assert ClaimMapping.listings([env]) == %{{1, "A"} => MapSet.new([{"mysteryScheme", "XYZ"}])}
    end

    # gr-6k4: a French listing's medipim fields map to their engine scheme atoms via CodeRegistry
    # (cipOrAcl7 -> :cip_acl7, acl13 -> :acl13). The whole GTIN family still folds to :gtin.
    test "French national fields map to their own engine schemes (cip_acl7, acl13)" do
      env =
        envelope(1, [id("A", "set", "cipOrAcl7", "4440813", 10), id("A", "set", "acl13", "3401344408137", 20)])

      assert ClaimMapping.listings([env]) ==
               %{{1, "A"} => MapSet.new([{:cip_acl7, "4440813"}, {:acl13, "3401344408137"}])}
    end

    test "the whole GTIN family still folds to :gtin (eanGtin12 + upc12 + usaGtinCode)" do
      env =
        envelope(1, [
          id("A", "set", "eanGtin12", "036000291452", 10),
          id("A", "add", "upc12", "036000291452", 20),
          id("A", "add", "usaGtinCode", "036000291452", 30)
        ])

      assert ClaimMapping.listings([env]) == %{{1, "A"} => MapSet.new([{:gtin, "00036000291452"}])}
    end
  end

  # ── partition / shared ──────────────────────────────────────────────────────
  describe "partition" do
    test "a restricted (in-store) GTIN lands in the shared set" do
      env = envelope(1, [id("A", "add", "gtin", "02000000000000", 10), id("A", "set", "cnk", "111", 20)])
      %{shared: shared} = ClaimMapping.build([env])
      assert shared == MapSet.new([{:gtin, "02000000000000"}])
    end

    test "bridging codes (cnk, normal gtin) are not shared" do
      env = envelope(1, [id("A", "set", "cnk", "111", 10), id("A", "add", "gtin", "5012345678900", 20)])
      assert ClaimMapping.build([env]).shared == MapSet.new()
    end
  end

  # ── claim shapes ─────────────────────────────────────────────────────────────
  describe "claims" do
    test "one identity claim per listing, carrying the folded code-set" do
      env = envelope(7, [id("A", "set", "cnk", "111", 10), id("B", "set", "cnk", "222", 10)])
      ids = Enum.filter(ClaimMapping.build([env]).claims, &(&1.kind == :identity))
      assert length(ids) == 2
      refs = ids |> Enum.map(& &1.data.ref) |> Enum.sort()
      assert refs == ["7:A", "7:B"]
    end

    test "attribute is anchored to the listing's primary code (CNK ▸ GTIN)" do
      env =
        envelope(1, [
          id("A", "set", "cnk", "111", 10),
          id("A", "add", "gtin", "5012345678900", 10),
          %{
            "recorded_at" => 20,
            "source" => "A",
            "op" => "set",
            "kind" => "attribute",
            "field" => "name",
            "locale" => "fr",
            "value" => "Crème"
          }
        ])

      attr = Enum.find(ClaimMapping.build([env]).claims, &(&1.kind == :attribute))
      assert attr.data.code == {:cnk, "111"}
      assert attr.data.field == "name:fr"
      assert attr.data.value == "Crème"
    end

    test "grouping points every code at the legacy entity" do
      env = envelope(99, [id("A", "set", "cnk", "111", 10)])
      grp = Enum.find(ClaimMapping.build([env]).claims, &(&1.kind == :grouping))
      assert grp.data == %{code: {:cnk, "111"}, product: 99}
    end

    # PR #3 review (CodeRabbit): a sourced event must not re-home onto another listing.
    test "a sourced event whose listing was delisted is skipped, not re-anchored" do
      env =
        envelope(1, [
          id("A", "set", "cnk", "100", 10),
          id("A", "delete", "cnk", "A", 20),
          id("B", "set", "cnk", "200", 10),
          %{
            "recorded_at" => 30,
            "source" => "A",
            "op" => "set",
            "kind" => "attribute",
            "field" => "name",
            "value" => "X"
          }
        ])

      # listing A folded to empty -> its attribute has no anchor -> dropped (never anchored to B)
      assert Enum.filter(ClaimMapping.build([env]).claims, &(&1.kind == :attribute)) == []
    end

    # gr-gh0: periods are half-open, so the period opening at an instant owns it. Right for
    # identity, wrong for a parting attribute — a source delisting and stating facts in the same
    # batch is describing what it HAD. The boundary is pinned in both directions.
    test "attribute at the exact delisting instant anchors to the closing period's codes" do
      day2 = 2 * 86_400

      env =
        envelope(1, [
          id("A", "set", "cnk", "111", 10),
          id("A", "delete", "cnk", "A", day2),
          %{
            "recorded_at" => day2,
            "source" => "A",
            "op" => "set",
            "kind" => "attribute",
            "field" => "name",
            "value" => "Parting"
          }
        ])

      attr = Enum.find(ClaimMapping.build([env]).claims, &(&1.kind == :attribute))
      assert attr.data.code == {:cnk, "111"}
      assert ClaimMapping.rejected([env]) == []
    end

    test "attribute at the opening instant of a live period anchors to the new codes" do
      day2 = 2 * 86_400

      env =
        envelope(1, [
          id("A", "set", "cnk", "111", 10),
          id("A", "set", "cnk", "222", day2),
          %{
            "recorded_at" => day2,
            "source" => "A",
            "op" => "set",
            "kind" => "attribute",
            "field" => "name",
            "value" => "Fresh"
          }
        ])

      attr = Enum.find(ClaimMapping.build([env]).claims, &(&1.kind == :attribute))
      assert attr.data.code == {:cnk, "222"}
    end

    # PR #3 review (CodeRabbit): identity codes are emitted in a deterministic (sorted) order.
    test "identity claim codes are sorted" do
      env = envelope(1, [id("A", "set", "cnk", "999", 10), id("A", "add", "gtin", "5012345678900", 10)])
      idc = Enum.find(ClaimMapping.build([env]).claims, &(&1.kind == :identity))
      assert idc.data.codes == Enum.sort(idc.data.codes)
    end
  end

  # ── cross-entity behaviour through the engine ───────────────────────────────
  describe "through the engine" do
    test "two entities sharing a CNK cluster into one key, flagged as a collision" do
      envs = [
        envelope(1, [id("A", "set", "cnk", "100", 10)]),
        envelope(2, [id("B", "set", "cnk", "100", 10)])
      ]

      %{claims: claims, shared: shared} = ClaimMapping.build(envs)
      live = Substrate.current(claims)

      assert [_one_cluster] = Cluster.variants(live, shared)

      ledger =
        IdentityLedger.decide(IdentityLedger.new(), {:reconcile, Cluster.variants(live, shared), 10})
        |> Enum.reduce(IdentityLedger.new(), &IdentityLedger.evolve(&2, &1))

      collisions = Stewardship.detect_collisions(ledger.members, live, 10)
      assert [%Events.ConflictFlagged{subject: {:collision, _key}}] = collisions
    end
  end

  # ── the real 422156 fixture ─────────────────────────────────────────────────
  describe "real entity 422156" do
    setup do
      {:ok, env} = HistoryEnvelope.load(@fixture)
      %{env: env}
    end

    test "org 44 converged: dropped its old EAN, holds CNK + canonical GTIN", %{env: env} do
      l = ClaimMapping.listings([env])
      assert l[{422_156, "44"}] == MapSet.new([{:cnk, "3612173"}, {:gtin, "03282770146004"}])
      # the 2018 EAN it later removed must be gone
      refute MapSet.member?(l[{422_156, "44"}], {:gtin, "03282770049374"})
    end

    test "org 1035 kept its extra (never-removed) GTIN", %{env: env} do
      l = ClaimMapping.listings([env])
      assert MapSet.member?(l[{422_156, "1035"}], {:gtin, "03282770114577"})
      assert MapSet.member?(l[{422_156, "1035"}], {:cnk, "3612173"})
    end

    test "all three listings collapse to ONE surrogate key (legacy was right)", %{env: env} do
      result = ClaimMapping.build([env])
      assert result.shared == MapSet.new()

      assert [cluster] = clusters(result)
      assert MapSet.member?(cluster, {:cnk, "3612173"})
      assert MapSet.member?(cluster, {:gtin, "03282770146004"})
      assert MapSet.member?(cluster, {:gtin, "03282770114577"})

      minted =
        IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(result), 1})
        |> Enum.filter(&match?(%Events.IdentityMinted{}, &1))

      assert length(minted) == 1
    end
  end
end
