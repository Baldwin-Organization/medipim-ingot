# lanes_ingest_test.exs — the medipim adapter emits description/media lanes + edges (gr-kek).
#
# Acceptance for the lanes design over REAL data: the 422156 fixture's "descriptions" and
# "media" edge collections stop being member_of categories and become first-class records in
# their own lanes, each tied to the product by a describes/depicts edge. Brands/organizations/
# ATC stay collection membership.

alias GoldenRecord.{Lanes}

defmodule LanesIngestTest do
  use ExUnit.Case, async: true

  @fixture Path.join(__DIR__, "fixtures/medipim_be_422156.json")

  setup_all do
    {:ok, env} = HistoryEnvelope.load(@fixture)
    red = Rederivation.run([env], 1_700_000_000)
    %{red: red, gr: GoldenRecords.project(red)}
  end

  test "canonical claims carry the lane flavor: identity-with-entity + describes/depicts edges", %{red: _} do
    {:ok, env} = HistoryEnvelope.load(@fixture)
    canonical = ClaimMapping.canonical_claims([env])

    descriptions = Enum.filter(canonical, &(&1["kind"] == "identity" and &1["entity"] == "description"))
    media = Enum.filter(canonical, &(&1["kind"] == "identity" and &1["entity"] == "media"))
    edges = Enum.filter(canonical, &(&1["kind"] == "edge"))

    assert descriptions != []
    assert media != []
    assert Enum.all?(descriptions, &match?(["text_id:" <> _], &1["codes"]))
    assert Enum.all?(media, &match?(["asset_id:" <> _], &1["codes"]))
    assert Enum.map(edges, & &1["relation"]) |> Enum.uniq() |> Enum.sort() == ["depicts", "describes"]

    # the lane collections no longer leak into member_of
    member_of_collections = for c <- canonical, c["kind"] == "member_of", uniq: true, do: c["collection"]
    refute "descriptions" in member_of_collections
    refute "media" in member_of_collections
  end

  test "the lanes reconcile to their own keys alongside the product", %{red: red} do
    lanes = Lanes.partition_members(red.ledger.members)

    assert map_size(lanes.product) > 0
    assert map_size(lanes.description) > 0
    assert map_size(lanes.media) > 0
    assert Enum.all?(Map.keys(lanes.description), &String.starts_with?(&1, "DSC_"))
    assert Enum.all?(Map.keys(lanes.media), &String.starts_with?(&1, "MED_"))
  end

  test "the product page reaches descriptions and depicted media via edges, with provenance", %{
    red: red,
    gr: gr
  } do
    variants = Enum.flat_map(gr.records, & &1.variants)
    described = Enum.filter(variants, &(&1.descriptions != []))
    assert described != []

    for v <- described, d <- v.descriptions do
      assert d.via == :direct
      assert String.starts_with?(d.key, "DSC_")
      assert d.asserted_by != []
    end

    depicted = variants |> Enum.flat_map(& &1.media) |> Enum.filter(&is_binary(&1.asset))
    assert depicted != []
    assert Enum.all?(depicted, &String.starts_with?(&1.asset, "MED_"))

    # categories keep the true collections and lose the promoted ones
    collections = variants |> Enum.flat_map(& &1.categories) |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    refute "descriptions" in collections
    refute "media" in collections
    assert red.ledger.members |> Map.keys() |> Enum.any?(&String.starts_with?(&1, "SK_"))
  end
end
