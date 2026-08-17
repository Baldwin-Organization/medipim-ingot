# test/ingest/au_market_test.exs — the AU market is a registry data change (gr-sx7.1).
#
# Pins the three AU decisions from the export quality sweep (analysis/au-20260814):
#   * artgId is an IDENTITY code that never bridges — one ARTG registration covers many pack
#     sizes (3,807 live ARTG numbers sit on >1 entity in the export), so it gets the
#     restricted-GTIN treatment: folded into the code-set, marked shared, bridge grade :none.
#   * snomed* / supplierReference identify things in OTHER systems — never identity fields.
#   * leaflets are first-class media-lane records under their own :leaflet_id scheme (leaflet
#     ids come from a different medipim table than media asset ids — sharing :asset_id would
#     collide id-spaces).

defmodule AuMarketTest do
  use ExUnit.Case, async: true

  defp envelope(entity, events) do
    {:ok, env} =
      HistoryEnvelope.from_map(%{
        "schema_version" => "1",
        "source_system" => "medipim-au",
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

  defp media(op, collection, asset, at),
    do: %{"recorded_at" => at, "op" => op, "kind" => "media", "collection" => collection, "asset" => asset}

  defp product_clusters(%{claims: claims, shared: shared}),
    do: Cluster.variants(Lanes.identity_claims(Substrate.current(claims), :product), shared)

  describe "artgId" do
    test "is an identity field with its own scheme and NO bridge grade" do
      assert CodeRegistry.identity_field?("artgId")
      assert CodeRegistry.scheme("artgId") == :artg_id
      assert CodeRegistry.bridge_grade(:artg_id) == :none
    end

    test "two pack sizes sharing one ARTG number stay two products" do
      # The real AU pattern: distinct EANs, one shared ARTG registration.
      env1 =
        envelope(101, [
          id("1", "add", "ean", "9338475000364", 10),
          id("1", "set", "artgId", "207479", 20)
        ])

      env2 =
        envelope(102, [
          id("1", "add", "ean", "9338475065684", 10),
          id("1", "set", "artgId", "207479", 20)
        ])

      built = ClaimMapping.build([env1, env2])

      assert MapSet.member?(built.shared, {:artg_id, "207479"})

      clusters = product_clusters(built)
      assert length(clusters) == 2, "a shared ARTG number must never fuse two entities"
      assert Enum.all?(clusters, &MapSet.member?(&1, {:artg_id, "207479"}))
    end
  end

  describe "snomed* / supplierReference" do
    test "are external refs, never identity fields" do
      for field <-
            ~w(snomedCtpp snomedTpp snomedMpp snomedTp snomedMp snomedTpuu snomedMpuu supplierReference) do
        assert CodeRegistry.classification(field) == :external_ref
        refute CodeRegistry.identity_field?(field)
      end
    end
  end

  describe "replacement lifecycle (gr-sx7.4)" do
    defp attr(source, field, value, at),
      do: %{
        "recorded_at" => at,
        "source" => source,
        "op" => "set",
        "kind" => "attribute",
        "field" => field,
        "value" => value
      }

    test "an end-of-life entity answers 'replaced by X' instead of going dark" do
      # The real AU pattern (entity 10701): status := replaced, replacement := new-system id,
      # then the EAN removed and GTIN fields nulled — identity intentionally dies.
      day = 86_400

      env =
        envelope(10_701, [
          id("1", "add", "ean", "9338475000364", 1 * day),
          attr("1", "status", "active", 2 * day),
          attr("1", "status", "replaced", 100 * day),
          attr("1", "replacement", "M05EE5029F", 100 * day),
          id("1", "remove", "ean", "9338475000364", 110 * day),
          id("1", "set", "eanGtin13", nil, 110 * day)
        ])

      # Nothing is refused: the post-hoc statements anchor to the codes the source held (gr-4iu).
      assert ClaimMapping.rejected([env]) == []

      # As of any date the entity still held codes, the golden record answers "replaced by X".
      t = Temporal.run([env])
      epoch = ~D[1970-01-01]

      assert [%{product: 10_701, variants: [variant]}] =
               Temporal.golden_as_of(t.log, Date.add(epoch, 105))

      decisions = Map.new(variant.attributes)
      assert %{value: "replaced", status: :resolved} = decisions["status"]
      assert %{value: "M05EE5029F", status: :resolved} = decisions["replacement"]

      assert CodeRegistry.classification("replacement") == :external_ref

      # After the codes are nulled the identity is deliberately dead — no live record, in the
      # current-state fold and the as-of projection alike. The forwarding pointer is not lost:
      # it lives in every as-of projection before the death.
      assert Temporal.golden_as_of(t.log, Date.add(epoch, 200)) == []
      assert Rederivation.run([env], 200 * day) |> GoldenRecords.project() |> Map.fetch!(:records) == []
    end
  end

  describe "leaflets" do
    test "become media-lane records under :leaflet_id, distinct from same-numbered media assets" do
      env =
        envelope(103, [
          id("1", "add", "ean", "9338475000364", 10),
          media("add", "media", 3, 20),
          media("add", "leaflets", 3, 30)
        ])

      canonical = ClaimMapping.canonical_claims([env])
      lane_records = Enum.filter(canonical, &(&1["kind"] == "identity" and &1["entity"] == "media"))

      assert Enum.map(lane_records, & &1["codes"]) |> Enum.sort() == [["asset_id:3"], ["leaflet_id:3"]]

      # leaflets reach the product via depicts edges and never leak into member_of
      leaflet_edges =
        Enum.filter(canonical, &(&1["kind"] == "edge" and &1["from"] == "leaflet_id:3"))

      assert Enum.map(leaflet_edges, & &1["relation"]) |> Enum.uniq() == ["depicts"]
      refute Enum.any?(canonical, &(&1["kind"] == "member_of" and &1["collection"] == "leaflets"))

      assert Lanes.lane_of_scheme(:leaflet_id) == :media
    end
  end
end
