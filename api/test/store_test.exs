# Event-store contract: durable offsets, JSON round-trips, transactional indexed projections,
# and unlimited rebuild. async: false — these tests share the projection tables.

defmodule Api.StoreTest do
  use ExUnit.Case, async: false

  @d ~D[2026-03-01]

  setup do
    {:ok, :ok} = Api.Store.reset!()
    :ok
  end

  defp identity(source, ref, codes),
    do: Substrate.claim(source, :identity, %{ref: ref, codes: codes}, @d, @d)

  defp append!(events) do
    {:ok, :ok} = Api.Store.append(fn _state, _conn -> {:ok, events, :ok} end)
  end

  test "append stamps durable offsets and checkpoints projections in the same transaction" do
    append!([identity(:a, "A", [{:cnk, "111"}]), identity(:b, "B", [{:gtin, "05012345678900"}])])

    state = Api.Store.state()
    assert state.offset == 2
    assert map_size(state.current) == 2
    assert Enum.map(Api.Store.log(), & &1.order) == [1, 2]

    # the projection checkpoint matches what reads return
    %{rows: [[offset]]} =
      Postgrex.query!(
        Api.DB,
        ~s(SELECT "offset" FROM projection_checkpoints WHERE name = 'main'),
        []
      )

    assert offset == 2
  end

  test "events round-trip EXACTLY — tuples, MapSets, Dates" do
    mint = %Events.IdentityMinted{
      key: "SK_1",
      codes: MapSet.new([{:cnk, "111"}, {:gtin, "05012345678900"}]),
      recorded_at: @d
    }

    claim = identity(:a, "A", [{:cnk, "111"}])
    append!([claim, mint])

    assert [decoded_claim, decoded_mint] = Api.Store.log()
    assert decoded_claim == %{claim | order: 1}
    assert decoded_mint == %{mint | order: 2}
  end

  test "indexed state equals a pure full fold" do
    mint = %Events.IdentityMinted{
      key: "SK_1",
      codes: MapSet.new([{:cnk, "111"}]),
      recorded_at: @d
    }

    append!([identity(:a, "A", [{:cnk, "111"}]), mint])

    folded = Enum.reduce(Api.Store.log(), Api.State.new(), &Api.State.apply_event(&2, &1))
    assert Api.Store.state() == folded

    %{rows: [[1]]} = Postgrex.query!(Api.DB, "SELECT count(*) FROM current_claims", [])
    %{rows: [[1]]} = Postgrex.query!(Api.DB, "SELECT count(*) FROM identity_members", [])
    %{rows: [[1]]} = Postgrex.query!(Api.DB, "SELECT count(*) FROM code_ownership", [])
  end

  test "current product and code reads use per-key tables, not a log scan" do
    claim = identity(:a, "A", [{:cnk, "111"}])

    mint = %Events.IdentityMinted{
      key: "SK_1",
      codes: MapSet.new([{:cnk, "111"}]),
      recorded_at: @d
    }

    assigned = %Events.LegacyIdAssigned{key: "SK_1", legacy_id: 42, recorded_at: @d}
    append!([claim, mint, assigned])

    Postgrex.query!(Api.DB, "DELETE FROM events", [])

    assert {:ok, %{key: "SK_1", legacy_id: 42}} = Api.Reads.product(42)
    assert {:ok, %{products: [%{key: "SK_1"}]}} = Api.Reads.by_code("cnk", "111")
  end

  test "the writer fun sees the CURRENT state; {:error, _} rolls everything back" do
    append!([identity(:a, "A", [{:cnk, "111"}])])

    assert {:error, :nope} =
             Api.Store.append(fn state, _conn ->
               assert state.offset == 1
               {:error, :nope}
             end)

    assert length(Api.Store.log()) == 1
    assert Api.Store.state().offset == 1
  end

  test "concurrent writers serialize under the advisory lock — unique offsets, consistent state" do
    1..8
    |> Enum.map(fn i ->
      Task.async(fn ->
        Api.Store.append(fn _state, _conn ->
          {:ok, [identity(:"s#{i}", "R#{i}", [{:cnk, "#{1_000_000 + i}"}])], :ok}
        end)
      end)
    end)
    |> Task.await_many(30_000)

    offsets = Api.Store.log() |> Enum.map(& &1.order)
    assert offsets == Enum.to_list(1..8)
    assert Api.Store.state().offset == 8
  end

  test "projections are disposable: reads re-fold from zero when the checkpoint is gone" do
    append!([identity(:a, "A", [{:cnk, "111"}]), identity(:b, "B", [{:cnk, "222"}])])
    Api.ReadModels.reset!(Api.DB)

    state = Api.Store.state()
    assert state.offset == 2
    assert map_size(state.current) == 2
  end

  test "bootstrap recovers projections before listeners can start" do
    append!([identity(:a, "A", [{:cnk, "111"}]), identity(:b, "B", [{:cnk, "222"}])])
    Api.ReadModels.reset!(Api.DB)

    start_supervised!(Api.Bootstrap)

    assert Api.ReadModels.checkpoint_offset() == 2
    %{rows: [[2]]} = Postgrex.query!(Api.DB, "SELECT count(*) FROM current_claims", [])
  end

  test "rebuild! verifies healthy projections and repairs corrupted rows" do
    append!([identity(:a, "A", [{:cnk, "111"}])])
    assert {:ok, {:ok, 1}} = Api.Store.rebuild!()

    # corrupt a derived row — the log wins
    Postgrex.query!(Api.DB, "DELETE FROM current_claims", [])

    assert {:ok, {:repaired, 1}} = Api.Store.rebuild!()
    assert Api.Store.state().offset == 1
  end

  test "events_since returns the decoded tail — the change feed's substrate" do
    append!([identity(:a, "A", [{:cnk, "111"}]), identity(:b, "B", [{:cnk, "222"}])])

    assert [%Events.ClaimAsserted{order: 2}] = Api.Store.events_since(1)
    assert Api.Store.events_since(2) == []
  end

  test "an empty projection replays more than one internal page without a hard cap" do
    events =
      for i <- 1..5_001 do
        identity("source-#{i}", "R#{i}", [{:cnk, Integer.to_string(i)}])
      end

    append!(events)
    Api.ReadModels.reset!(Api.DB)

    assert {:ok, {:ok, 5_001}} = Api.Store.rebuild!()
    state = Api.Store.state()
    assert state.offset == 5_001
    assert map_size(state.current) == 5_001
    assert Api.ReadModels.checkpoint_offset() == 5_001
  end

  test "event payloads are inspectable JSON rather than Erlang terms" do
    append!([identity(:a, "A", [{:cnk, "111"}])])

    %{rows: [[payload]]} =
      Postgrex.query!(Api.DB, "SELECT payload::text FROM events WHERE \"offset\" = 1", [])

    decoded = JSON.decode!(payload)
    assert decoded["$type"] == "struct"
    assert decoded["module"] == "Events.ClaimAsserted"
    assert decoded["fields"]["source"]["value"] == "a"

    %{rows: [[nil]]} =
      Postgrex.query!(Api.DB, "SELECT to_regclass('public.snapshots')::text", [])
  end
end
