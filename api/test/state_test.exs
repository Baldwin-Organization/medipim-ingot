# Pure fold-state coverage (bead gr-l27): every event type the log can carry must fold — the
# snapshot is only as trustworthy as apply_event/2.

alias GoldenRecord.{Events, Substrate, Priority}

defmodule Api.StateTest do
  use ExUnit.Case, async: true

  @d ~D[2026-03-01]

  defp identity(source, ref, codes, order),
    do: %{Substrate.claim(source, :identity, %{ref: ref, codes: codes}, @d, @d) | order: order}

  defp attribute(source, code, field, value, order),
    do: %{
      Substrate.claim(source, :attribute, %{code: code, field: field, value: value}, @d, @d)
      | order: order
    }

  test "claims update the CURRENT view per slot — a re-assertion replaces, not appends" do
    s =
      Api.State.new()
      |> Api.State.apply_event(identity(:a, "A", [{:cnk, "111"}], 1))
      |> Api.State.apply_event(identity(:a, "A", [{:cnk, "111"}, {:gtin, "05012345678900"}], 2))

    assert [%{data: %{codes: codes}}] = Api.State.current_claims(s)
    assert length(codes) == 2
    assert s.offset == 2
  end

  test "identity events evolve the ledger" do
    mint = %Events.IdentityMinted{
      key: "SK_1",
      codes: MapSet.new([{:cnk, "111"}]),
      recorded_at: @d,
      order: 1
    }

    s = Api.State.new() |> Api.State.apply_event(mint)
    assert s.ledger.members == %{"SK_1" => MapSet.new([{:cnk, "111"}])}
  end

  test "flags dedupe by subject; a resolution closes them; attr picks become overrides" do
    flag = %Events.ConflictFlagged{
      subject: {:attr, "SK_1", :color},
      candidates: [],
      recorded_at: @d,
      order: 1
    }

    pick = %Events.ConflictResolved{
      subject: {:attr, "SK_1", :color},
      decision: {:pick, "ivory"},
      by: :sam,
      recorded_at: @d,
      order: 3
    }

    s = Api.State.new() |> Api.State.apply_all([flag, %{flag | order: 2}])
    assert [_only_one] = Api.State.open_flags(s)

    s = Api.State.apply_event(s, pick)
    assert Api.State.open_flags(s) == []
    assert %Events.ConflictResolved{} = s.overrides.attr[{"SK_1", :color}]
  end

  test "legacy assignments accumulate" do
    e = %Events.LegacyIdAssigned{key: "SK_1", legacy_id: 422_156, recorded_at: @d, order: 1}
    s = Api.State.new() |> Api.State.apply_event(e)
    assert s.assigned == %{"SK_1" => 422_156}
  end

  test "golden/2 projects from state alone — claims + ledger + steward overrides" do
    priority = Priority.new(%{}, [[:a], [:b]])

    mint = %Events.IdentityMinted{
      key: "SK_1",
      codes: MapSet.new([{:cnk, "111"}]),
      recorded_at: @d,
      order: 3
    }

    s =
      Api.State.new()
      |> Api.State.apply_all([
        identity(:a, "A", [{:cnk, "111"}], 1),
        attribute(:a, {:cnk, "111"}, :name, "Sunscreen", 2),
        mint
      ])

    assert [%{variants: [v]}] = Api.State.golden(s, priority)
    assert v.key == "SK_1"
    assert {:name, %{value: "Sunscreen"}} = List.keyfind(v.attributes, :name, 0)
  end
end
