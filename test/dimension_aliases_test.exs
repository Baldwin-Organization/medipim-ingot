alias GoldenRecord.{DimensionAliases, Substrate}

defmodule DimensionAliasesTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The dimension-alias seam (GH #129): an injected old→new field-name map applied where claims
  are normalized on the way in, so a source-side field rename folds as ONE dimension. The PHP
  port pins the same scenarios (DimensionAliasesTest.php) so parity guards the remap semantics.
  """

  # ── resolve/2 ──────────────────────────────────────────────────────────────

  test "a name not in the map passes through" do
    assert DimensionAliases.resolve(%{"a" => "b"}, "c") == "c"
    assert DimensionAliases.resolve(%{}, "a") == "a"
    assert DimensionAliases.resolve(nil, "a") == "a"
  end

  test "chains resolve transitively to the terminal name" do
    aliases = %{"a" => "b", "b" => "c"}
    assert DimensionAliases.resolve(aliases, "a") == "c"
    assert DimensionAliases.resolve(aliases, "b") == "c"
  end

  test "a cycle terminates instead of looping" do
    aliases = %{"a" => "b", "b" => "a"}
    assert DimensionAliases.resolve(aliases, "a") in ["a", "b"]
  end

  test "a locale suffix rides along on the aliased field part" do
    assert DimensionAliases.resolve(%{"name" => "title"}, "name:fr") == "title:fr"
  end

  test "an exact whole-name entry wins over the bare-field entry" do
    aliases = %{"name" => "title", "name:fr" => "frenchTitle"}
    assert DimensionAliases.resolve(aliases, "name:fr") == "frenchTitle"
    assert DimensionAliases.resolve(aliases, "name:nl") == "title:nl"
  end

  test "non-binary names pass through" do
    assert DimensionAliases.resolve(%{"a" => "b"}, :atom_scheme) == :atom_scheme
  end

  # ── normalize/2 over engine claims ─────────────────────────────────────────

  defp attr(field, value, order) do
    c =
      Substrate.claim(
        "A",
        :attribute,
        %{code: {:cnk, "1234567"}, field: field, value: value},
        order,
        order
      )

    %{c | order: order}
  end

  defp member(collection, member, order) do
    c =
      Substrate.claim(
        "A",
        :member_of,
        %{member_code: {:cnk, "1234567"}, collection: {collection, member}},
        order,
        order
      )

    %{c | order: order}
  end

  test "an attribute claim's field is rewritten to the terminal alias" do
    [normalized] = DimensionAliases.normalize([attr("name", "x", 1)], %{"name" => "title"})
    assert normalized.data.field == "title"
  end

  test "a member_of edge's collection name is rewritten, the member is not" do
    [normalized] = DimensionAliases.normalize([member("brands", "42", 1)], %{"brands" => "makers"})
    assert normalized.kind == :edge
    assert normalized.data.to == {"makers", "42"}
    assert normalized.data.from == {:cnk, "1234567"}
  end

  test "identity claims are untouched — schemes are not field names" do
    identity =
      Substrate.claim("A", :identity, %{ref: "1:A", codes: [{:cnk, "1234567"}]}, 1, 1)

    assert DimensionAliases.normalize([identity], %{"cnk" => "nope"}) == [identity]
  end

  test "both spellings of a renamed field collapse to one slot, later order wins" do
    claims = [attr("name", "Old", 1), attr("title", "New", 2)]

    [survivor] =
      claims |> DimensionAliases.normalize(%{"name" => "title"}) |> Substrate.current()

    assert survivor.data.field == "title"
    assert survivor.data.value == "New"
  end

  # ── the seam threads through the projection entry ──────────────────────────

  defp envelope(entity, events) do
    {:ok, env} =
      HistoryEnvelope.from_map(%{
        "schema_version" => "1",
        "legacy_entity" => entity,
        "events" => events
      })

    env
  end

  defp rename_envelope do
    envelope(1, [
      %{
        "recorded_at" => 10,
        "source" => "A",
        "op" => "set",
        "kind" => "identity",
        "scheme" => "cnk",
        "code" => "1234567"
      },
      %{
        "recorded_at" => 10,
        "source" => "A",
        "op" => "set",
        "kind" => "attribute",
        "field" => "name",
        "value" => "Old"
      },
      %{
        "recorded_at" => 20,
        "source" => "A",
        "op" => "set",
        "kind" => "attribute",
        "field" => "title",
        "value" => "New"
      }
    ])
  end

  test "GoldenRecords.from_envelopes: without aliases a rename splits the dimension" do
    %{records: [%{variants: [variant]}]} = GoldenRecords.from_envelopes([rename_envelope()], 100)

    assert variant.attributes |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["name", "title"]
  end

  test "GoldenRecords.from_envelopes: with aliases the rename folds as one dimension" do
    %{records: [%{variants: [variant]}]} =
      GoldenRecords.from_envelopes(
        [rename_envelope()],
        100,
        GoldenRecords.default_priority(),
        %{"name" => "title"}
      )

    assert [{"title", decision}] = variant.attributes
    assert decision.value == "New"
  end

  # gr-1y5: the projection returns the alias-normalized log, so the customer read layer
  # (Api.get / History.now over that log) folds the SAME dimension the projection did — the
  # stale spelling must not survive in a second Substrate slot.
  test "the engine read layer over the projected log agrees with the projection" do
    priority = GoldenRecords.default_priority()

    %{log: log} =
      GoldenRecords.from_envelopes([rename_envelope()], 100, priority, %{"name" => "title"})

    {:ok, %{variant: variant}} = GoldenRecord.Api.lookup(log, {:cnk, "1234567"}, priority)

    assert [{"title", decision}] = variant.attributes
    assert decision.value == "New"
  end
end
