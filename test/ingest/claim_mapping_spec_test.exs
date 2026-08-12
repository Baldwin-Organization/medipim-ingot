# test/ingest/claim_mapping_spec_test.exs
#
# Pins the behaviour that docs/CLAIM_MAPPING_SPEC.md describes, against the real medipim delta
# histories. If the mapping changes, one of these fails and the spec gets updated with it —
# a spec nobody executes is a spec that drifts.

defmodule ClaimMappingSpecTest do
  use ExUnit.Case, async: true

  @fixtures [
    "test/ingest/fixtures/medipim_be_422156.json",
    "test/ingest/fixtures/medipim_fr_347025.json"
  ]

  setup_all do
    claims = @fixtures |> Enum.map(&HistoryEnvelope.load!/1) |> ClaimMapping.build() |> Map.fetch!(:claims)
    %{claims: claims, attrs: Enum.filter(claims, &(&1.kind == :attribute))}
  end

  describe "cardinality" do
    test "a one-element list becomes its element, so the two spellings stop competing", %{attrs: attrs} do
      species = Enum.filter(attrs, &(&1.data.field == "allowedSpecies"))

      assert species != [], "fixture no longer exercises allowedSpecies"
      refute Enum.any?(species, &is_list(&1.data.value))
      assert Enum.all?(species, &(&1.data.value == "human"))
    end

    test "no attribute claim carries a list value", %{attrs: attrs} do
      assert Enum.filter(attrs, &is_list(&1.data.value)) == []
    end
  end

  describe "dimensions" do
    test "a localised field resolves per locale, not per field", %{attrs: attrs} do
      dims = attrs |> Enum.map(& &1.data.field) |> Enum.uniq()

      assert "name:nl" in dims
      assert "name:fr" in dims
      refute "name" in dims, "a localised field must never collapse onto the bare field name"
    end
  end

  describe "documented gaps — these pin CURRENT behaviour, not desired behaviour" do
    test "quantities are NOT unit-converted, so a mixed-representation field stays unresolved",
         %{attrs: attrs} do
      values =
        attrs
        |> Enum.filter(&(&1.data.field == "weight"))
        |> Enum.map(& &1.data.value)
        |> Enum.sort_by(&inspect/1)

      # Three sources, three representations. The engine cannot prove the integer form is grams,
      # so it does not convert — see the OPEN QUESTION in docs/CLAIM_MAPPING_SPEC.md.
      assert "30_g" in values
      assert Enum.any?(values, &is_integer/1)

      decision = Survivorship.decide("weight", entries(attrs, "weight"), Priority.new(%{}, []))
      assert decision.status == :needs_review
      assert decision.value == nil
    end

    test "a deleted field and a field set to null are both emitted as nil today", %{attrs: attrs} do
      nils = Enum.filter(attrs, &is_nil(&1.data.value))

      assert nils != [], "fixture no longer exercises null values"

      # Both spellings collapse to the same claim shape. The spec records that they are different
      # statements; separating them is an open decision, not a bug fixed here.
      assert Enum.any?(nils, &(&1.data.field == "status"))
    end
  end

  describe "a claim is about the identifiers its source held when it spoke" do
    test "a source that later delisted keeps everything it said while it held codes", %{attrs: attrs} do
      # Sources 2 and 888 held codes for years, then removed them. The old final-state fold
      # erased their whole history the moment the last code went away.
      sources = attrs |> Enum.map(& &1.source) |> MapSet.new()

      assert MapSet.member?(sources, "2")
      assert MapSet.member?(sources, "888")
    end

    test "an event becomes one claim per code its source held", %{attrs: attrs} do
      # Listing 1035 held cnk + two gtins in its last period, so one event from it yields three
      # claims — the same fact reachable from every identifier the source gave it.
      by_event =
        attrs
        |> Enum.filter(&(&1.source == "1035"))
        |> Enum.group_by(&{&1.data.field, &1.data.value, &1.valid_from})
        |> Map.values()
        |> Enum.map(&length/1)

      assert Enum.max(by_event) > 1, "no event fanned out across its source's codes"
    end

    test "an event that identifies nothing is refused, not dropped" do
      rejected = @fixtures |> Enum.map(&HistoryEnvelope.load!/1) |> ClaimMapping.rejected()

      reasons = rejected |> Enum.map(& &1.reason) |> Enum.frequencies()
      assert reasons[:source_held_no_code] > 0
      assert reasons[:unsourced] > 0

      # 4996 and 5480 never assert a code anywhere in either fixture.
      never_identify =
        rejected |> Enum.map(& &1.source) |> Enum.uniq() |> Enum.reject(&is_nil/1) |> Enum.sort()

      assert "4996" in never_identify
      assert "5480" in never_identify
    end

    test "every rejection carries a reason and enough to find the event" do
      rejected = @fixtures |> Enum.map(&HistoryEnvelope.load!/1) |> ClaimMapping.rejected()

      assert Enum.all?(rejected, fn r ->
               is_integer(r.entity) and r.reason in [:unsourced, :source_held_no_code] and
                 is_binary(r.detail) and is_integer(r.recorded_at)
             end)
    end
  end

  describe "the spec table matches the fixtures" do
    test "every field the spec marks as reaching a claim actually does", %{attrs: attrs} do
      produced = attrs |> Enum.map(&(&1.data.field |> String.split(":") |> hd())) |> MapSet.new()
      {documented, dropped} = spec_table()

      assert MapSet.size(documented) == 38, "the spec table did not parse"
      # Only fields whose sole sources never identify anything: 4996 and 5480.
      assert MapSet.size(dropped) == 6

      assert MapSet.difference(MapSet.difference(documented, dropped), produced)
             |> MapSet.to_list() == [],
             "the spec claims a field reaches a claim, but the mapping drops it"
    end

    test "every field the spec marks as dropped really is dropped", %{attrs: attrs} do
      produced = attrs |> Enum.map(&(&1.data.field |> String.split(":") |> hd())) |> MapSet.new()
      {_documented, dropped} = spec_table()

      assert MapSet.intersection(dropped, produced) |> MapSet.to_list() == [],
             "the spec says these are dropped, but they now reach a claim — good news, update the spec"
    end

    test "the delisting half of the anchor gap is closed", %{attrs: attrs} do
      # 92 -> 228 claims, 5 -> 8 sourced. Only 4996 and 5480 reach nothing, and they identify
      # nothing. If these move, gr-4iu moved with them and the spec needs updating.
      assert length(attrs) == 228

      sourced = attrs |> Enum.map(& &1.source) |> Enum.reject(&is_nil/1) |> Enum.uniq()
      assert length(sourced) == 8
      refute "4996" in sourced
      refute "5480" in sourced
    end

    test "the anchor gap is real: four sources contribute no codes at all" do
      envelopes = Enum.map(@fixtures, &HistoryEnvelope.load!/1)
      anchored = ClaimMapping.listings(envelopes) |> Map.keys() |> MapSet.new()

      asserting =
        for env <- envelopes,
            ev <- env.events,
            ev.kind == :attribute,
            not is_nil(ev.source),
            into: MapSet.new(),
            do: {env.legacy_entity, ev.source}

      orphaned = MapSet.difference(asserting, anchored) |> Enum.map(&elem(&1, 1)) |> Enum.sort()

      assert orphaned == ["2", "4996", "5480", "888"]
    end
  end

  # field name -> is it marked dropped, from the spec's own table
  defp spec_table do
    rows =
      "docs/CLAIM_MAPPING_SPEC.md"
      |> File.read!()
      |> then(&Regex.scan(~r/^\| `([a-zA-Z]+)` \| \d+ \|.*\| (\*\*yes\*\*|—) \|$/m, &1))

    {
      MapSet.new(rows, fn [_, field, _] -> field end),
      rows |> Enum.filter(fn [_, _, d] -> d == "**yes**" end) |> MapSet.new(&Enum.at(&1, 1))
    }
  end

  defp entries(attrs, field) do
    attrs
    |> Enum.filter(&(&1.data.field == field))
    |> Enum.map(&%{source: &1.source, value: &1.data.value, order: &1.order})
  end
end
