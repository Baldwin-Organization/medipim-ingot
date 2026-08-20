alias GoldenRecord.{Events, Substrate, Priority, History}

defmodule BitemporalHistoryTest do
  use ExUnit.Case, async: true

  @priority Priority.new(%{}, [])
  @code {:cnk, "1000001"}

  defp timestamp(date, hour \\ 12), do: DateTime.new!(date, Time.new!(hour, 0, 0), "Etc/UTC")

  defp claims(name, suffix \\ "") do
    [
      Substrate.claim("supplier", :identity, %{ref: "P-1", codes: [@code]}, ~D[2026-01-01], ~D[2026-01-01]),
      Substrate.claim(
        "supplier",
        :attribute,
        %{code: @code, field: "name", value: name},
        ~D[2026-01-01],
        ~D[2026-01-01]
      ),
      Substrate.claim(
        "supplier",
        :grouping,
        %{code: @code, product: "product-#{suffix}"},
        ~D[2026-01-01],
        ~D[2026-01-01]
      ),
      Substrate.claim(
        "supplier",
        :media,
        %{asset: {:dam, "front#{suffix}"}, target: @code, role: :primary, uri: "https://#{suffix}"},
        ~D[2026-01-01],
        ~D[2026-01-01]
      ),
      Substrate.claim(
        "supplier",
        :edge,
        %{from: @code, relation: :contains, to: {:substance_id, "water#{suffix}"}},
        ~D[2026-01-01],
        ~D[2026-01-01]
      )
    ]
  end

  defp revision(revision, operation, active, claims, valid_from, valid_to, recorded_at, order) do
    %Events.SourceRecordRevised{
      source: "supplier",
      ref: "P-1",
      revision: revision,
      operation: operation,
      active: active,
      claims: claims,
      fingerprint: revision,
      valid_from: valid_from,
      valid_to: valid_to,
      recorded_at: recorded_at,
      order: order
    }
  end

  defp key_binding do
    %Events.SourceRecordKeyBound{
      source: "supplier",
      ref: "P-1",
      lane: :product,
      key: "SK_1",
      recorded_at: timestamp(~D[2026-01-10]),
      order: 2
    }
  end

  defp variant(log, known_at, effective_at) do
    case History.project_bitemporal(log, known_at, effective_at, @priority) do
      [] -> nil
      groups -> groups |> Enum.flat_map(& &1.variants) |> List.first()
    end
  end

  defp value(variant, field),
    do: variant.attributes |> Enum.find_value(fn {name, decision} -> name == field && decision.value end)

  test "a future revision is known without appearing before its effective date" do
    old =
      revision("1", :replace, true, claims("Old", "old"), ~D[2026-01-01], nil, timestamp(~D[2026-01-10]), 1)

    future =
      revision(
        "2",
        :replace,
        true,
        claims("Future", "future"),
        ~D[2026-03-01],
        nil,
        timestamp(~D[2026-01-15]),
        3
      )

    log = [old, key_binding(), future]

    assert value(variant(log, timestamp(~D[2026-01-20]), ~D[2026-02-28]), "name") == "Old"
    assert value(variant(log, timestamp(~D[2026-01-20]), ~D[2026-03-01]), "name") == "Future"
    assert value(variant(log, timestamp(~D[2026-01-12]), ~D[2026-03-01]), "name") == "Old"
  end

  test "a late bounded correction changes later knowledge only and the prior revision reappears" do
    old =
      revision("1", :replace, true, claims("Old"), ~D[2026-01-01], nil, timestamp(~D[2026-01-10]), 1)

    correction =
      revision(
        "2",
        :replace,
        true,
        claims("Corrected"),
        ~D[2026-02-01],
        ~D[2026-02-10],
        timestamp(~D[2026-04-01]),
        3
      )

    log = [old, key_binding(), correction]

    assert value(variant(log, timestamp(~D[2026-03-01]), ~D[2026-02-05]), "name") == "Old"
    assert value(variant(log, timestamp(~D[2026-04-02]), ~D[2026-02-05]), "name") == "Corrected"
    assert value(variant(log, timestamp(~D[2026-04-02]), ~D[2026-02-10]), "name") == "Old"
  end

  test "a bounded withdrawal hides all fact kinds only inside its interval" do
    old =
      revision("1", :replace, true, claims("Old"), ~D[2026-01-01], nil, timestamp(~D[2026-01-10]), 1)

    withdrawn =
      revision(
        "2",
        :withdraw,
        false,
        old.claims,
        ~D[2026-06-01],
        ~D[2026-06-05],
        timestamp(~D[2026-05-01]),
        3
      )

    log = [old, key_binding(), withdrawn]

    assert variant(log, timestamp(~D[2026-05-02]), ~D[2026-06-03]) == nil

    restored = variant(log, timestamp(~D[2026-05-02]), ~D[2026-06-05])
    assert restored.key == "SK_1"
    assert value(restored, "name") == "Old"
    assert length(restored.media) == 1
    assert length(restored.substances) == 1
  end

  test "open withdrawal and reactivation preserve the bound key" do
    old =
      revision("1", :replace, true, claims("Old"), ~D[2026-01-01], nil, timestamp(~D[2026-01-10]), 1)

    withdrawn =
      revision("2", :withdraw, false, old.claims, ~D[2026-06-01], nil, timestamp(~D[2026-05-01]), 3)

    reactivated =
      revision(
        "3",
        :reactivate,
        true,
        claims("Back"),
        ~D[2026-07-01],
        nil,
        timestamp(~D[2026-06-01]),
        4
      )

    log = [old, key_binding(), withdrawn, reactivated]

    assert variant(log, timestamp(~D[2026-06-15]), ~D[2026-06-15]) == nil
    assert %{key: "SK_1"} = back = variant(log, timestamp(~D[2026-07-02]), ~D[2026-07-01])
    assert value(back, "name") == "Back"
  end

  test "a later stamped resolution beats an earlier unstamped one (order: nil)" do
    claim =
      Substrate.claim(
        "supplier",
        :attribute,
        %{code: @code, field: "name", value: "Original"},
        ~D[2026-01-01],
        ~D[2026-01-01]
      )
      |> Map.put(:order, 2)

    identity =
      Substrate.claim(
        "supplier",
        :identity,
        %{ref: "P-1", codes: [@code]},
        ~D[2026-01-01],
        ~D[2026-01-01]
      )
      |> Map.put(:order, 1)

    mint = %Events.IdentityMinted{
      key: "SK_1",
      codes: MapSet.new(identity.data.codes),
      recorded_at: ~D[2026-01-01],
      order: 3
    }

    resolve = fn value, order ->
      %Events.ConflictResolved{
        subject: {:attr, "SK_1", "name"},
        decision: {:pick, value},
        by: "steward",
        valid_from: ~D[2026-02-01],
        valid_to: nil,
        recorded_at: timestamp(~D[2026-04-01]),
        order: order
      }
    end

    log = [identity, claim, mint, resolve.("A", nil), resolve.("B", 42)]

    assert value(variant(log, timestamp(~D[2026-04-02]), ~D[2026-02-05]), "name") == "B"
  end

  test "steward decisions, merges, and splits obey both clocks and bounded intervals" do
    claim =
      Substrate.claim(
        "supplier",
        :attribute,
        %{code: @code, field: "name", value: "Original"},
        ~D[2026-01-01],
        ~D[2026-01-01]
      )
      |> Map.put(:order, 2)

    identity =
      Substrate.claim(
        "supplier",
        :identity,
        %{ref: "P-1", codes: [@code, {:gtin, "05012345678900"}]},
        ~D[2026-01-01],
        ~D[2026-01-01]
      )
      |> Map.put(:order, 1)

    mint = %Events.IdentityMinted{
      key: "SK_1",
      codes: MapSet.new(identity.data.codes),
      recorded_at: ~D[2026-01-01],
      order: 3
    }

    override = %Events.ConflictResolved{
      subject: {:attr, "SK_1", "name"},
      decision: {:pick, "Manual"},
      by: "steward",
      valid_from: ~D[2026-02-01],
      valid_to: ~D[2026-02-10],
      recorded_at: timestamp(~D[2026-04-01]),
      order: 4
    }

    log = [identity, claim, mint, override]

    assert value(variant(log, timestamp(~D[2026-03-01]), ~D[2026-02-05]), "name") == "Original"
    assert value(variant(log, timestamp(~D[2026-04-02]), ~D[2026-02-05]), "name") == "Manual"
    assert value(variant(log, timestamp(~D[2026-04-02]), ~D[2026-02-10]), "name") == "Original"

    second = MapSet.new([{:cnk, "2000002"}])

    merged = %Events.IdentitiesMerged{
      from: ["SK_1", "SK_2"],
      into: "SK_1",
      valid_from: ~D[2026-02-01],
      valid_to: ~D[2026-02-10],
      recorded_at: timestamp(~D[2026-04-01]),
      order: 6
    }

    split = %Events.IdentitySplit{
      key: "SK_1",
      kept_codes: MapSet.new([@code]),
      into: [{"SK_3", MapSet.new([{:gtin, "05012345678900"}])}],
      valid_from: ~D[2026-03-01],
      valid_to: ~D[2026-03-10],
      recorded_at: timestamp(~D[2026-04-01]),
      order: 7
    }

    identity_log = [
      mint,
      %Events.IdentityMinted{key: "SK_2", codes: second, recorded_at: ~D[2026-01-01], order: 5},
      merged,
      split
    ]

    assert map_size(History.state_bitemporal(identity_log, timestamp(~D[2026-04-02]), ~D[2026-02-05]).members) ==
             1

    assert map_size(History.state_bitemporal(identity_log, timestamp(~D[2026-04-02]), ~D[2026-02-10]).members) ==
             2

    split_state = History.state_bitemporal([mint, split], timestamp(~D[2026-04-02]), ~D[2026-03-05])
    assert Map.has_key?(split_state.members, "SK_3")

    expired_split = History.state_bitemporal([mint, split], timestamp(~D[2026-04-02]), ~D[2026-03-10])
    refute Map.has_key?(expired_split.members, "SK_3")
  end
end
