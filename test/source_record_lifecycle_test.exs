defmodule SourceRecordLifecycleTest do
  use ExUnit.Case, async: true

  @day1 ~D[2026-07-01]
  @day2 ~D[2026-07-02]
  @day3 ~D[2026-07-03]
  @old_code {:cnk, "100"}
  @new_code {:cnk, "200"}

  defp claim(kind, data, at \\ @day1),
    do: Substrate.claim("supplier", kind, data, at, at)

  defp replace_claims(code \\ @old_code) do
    [
      claim(:identity, %{ref: "P-1", codes: [code]}),
      claim(:attribute, %{code: code, field: "name:en", value: "Old name"}),
      claim(:grouping, %{code: code, product: 42}),
      claim(:media, %{asset: {:dam, "front"}, target: code, role: :primary, uri: "https://old"}),
      claim(:edge, %{from: code, relation: :contains, to: {:substance_id, "water"}})
    ]
  end

  defp revise!(current, revision, operation, claims, extra) do
    opts =
      Keyword.merge(
        [
          source: "supplier",
          ref: "P-1",
          revision: revision,
          operation: operation,
          claims: claims,
          recorded_at: @day2,
          valid_from: @day2
        ],
        extra
      )

    assert {:ok, event} = SourceRecords.revise(current, opts)
    event
  end

  test "replace removes every omitted fact kind and patch preserves omissions" do
    first = revise!(nil, "1", :replace, replace_claims(), recorded_at: @day1, valid_from: @day1)

    replacement =
      revise!(first, "2", :replace, [claim(:identity, %{ref: "P-1", codes: [@old_code]}, @day2)],
        base_revision: "1"
      )

    assert Enum.map(replacement.claims, & &1.kind) == [:identity]

    patch =
      revise!(
        first,
        "2",
        :patch,
        [claim(:attribute, %{code: @old_code, field: "name:en", value: "New name"}, @day2)],
        base_revision: "1"
      )

    assert Enum.sort(Enum.map(patch.claims, & &1.kind)) ==
             [:attribute, :edge, :grouping, :identity, :media]

    assert Enum.find(patch.claims, &(&1.kind == :attribute)).data.value == "New name"
  end

  test "patch can explicitly remove one fact without touching the others" do
    first = revise!(nil, "1", :replace, replace_claims(), recorded_at: @day1, valid_from: @day1)
    media = Enum.find(first.claims, &(&1.kind == :media))

    patch =
      revise!(first, "2", :patch, [],
        base_revision: "1",
        remove_slots: [Substrate.local_slot(media)]
      )

    refute Enum.any?(patch.claims, &(&1.kind == :media))
    assert Enum.any?(patch.claims, &(&1.kind == :attribute))
    assert Enum.any?(patch.claims, &(&1.kind == :edge))
  end

  test "withdraw removes all contributions and reactivation accepts a fresh complete record" do
    first = revise!(nil, "1", :replace, replace_claims(), recorded_at: @day1, valid_from: @day1)
    withdrawn = revise!(first, "2", :withdraw, [], base_revision: "1")

    assert withdrawn.active == false
    assert SourceRecords.claims(withdrawn) == []
    assert length(withdrawn.claims) == 5

    reactivated =
      revise!(
        withdrawn,
        "3",
        :reactivate,
        [claim(:identity, %{ref: "P-1", codes: [@new_code]}, @day3)],
        base_revision: "2",
        recorded_at: @day3,
        valid_from: @day3
      )

    assert reactivated.active
    assert [%{data: %{codes: [@new_code]}}] = SourceRecords.claims(reactivated)
  end

  test "a withdrawn record reactivates under its old surrogate key even with entirely new codes" do
    old_cluster = MapSet.new([@old_code])
    first_events = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, [old_cluster], @day1})
    first_ledger = Enum.reduce(first_events, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1))
    assert Map.has_key?(first_ledger.members, "SK_1")

    withdraw_events = IdentityLedger.decide(first_ledger, {:reconcile, [], @day2})
    withdrawn_ledger = Enum.reduce(withdraw_events, first_ledger, &IdentityLedger.evolve(&2, &1))
    refute Map.has_key?(withdrawn_ledger.members, "SK_1")

    new_cluster = MapSet.new([@new_code])

    events =
      IdentityLedger.decide(
        withdrawn_ledger,
        {:reconcile, [new_cluster], MapSet.new(), %{new_cluster => ["SK_1"]}, @day3}
      )

    assert [%Events.IdentityMembersChanged{key: "SK_1", codes: ^new_cluster}] = events
    refute Enum.any?(events, &match?(%Events.IdentityMinted{}, &1))
  end

  test "revisions are idempotent and reject stale or conflicting writers" do
    claims = replace_claims()
    first = revise!(nil, "1", :replace, claims, recorded_at: @day1, valid_from: @day1)

    assert {:replay, ^first} =
             SourceRecords.revise(first,
               source: "supplier",
               ref: "P-1",
               revision: "1",
               operation: :replace,
               claims: claims,
               recorded_at: @day1,
               valid_from: @day1
             )

    assert {:error, {409, _}} =
             SourceRecords.revise(first,
               source: "supplier",
               ref: "P-1",
               revision: "1",
               operation: :replace,
               claims: [claim(:identity, %{ref: "P-1", codes: [@new_code]})],
               recorded_at: @day1,
               valid_from: @day1
             )

    assert {:error, {412, _}} =
             SourceRecords.revise(first,
               source: "supplier",
               ref: "P-1",
               revision: "2",
               base_revision: "stale",
               operation: :patch,
               claims: [],
               recorded_at: @day2,
               valid_from: @day2
             )
  end
end
