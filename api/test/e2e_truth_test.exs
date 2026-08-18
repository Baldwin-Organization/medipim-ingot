# The end-to-end truth test (bead gr-d91): the API cannot disagree with the engine.
#
# The real 422156 fixture goes in over HTTP; the answer that comes out must equal what the engine
# produces when fed the same envelope DIRECTLY (same fold, same keys, same codes, same resolved
# attributes). Then: replaying the backfill changes NOTHING (byte-identical snapshot), and
# rebuild! re-folds the whole realistic log from zero and confirms the snapshot. async: false.

alias GoldenRecord.{Priority, History}

defmodule Api.E2eTruthTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @fixture Path.expand("../../test/ingest/fixtures/medipim_be_422156.json", __DIR__)

  setup do
    {:ok, :ok} = Api.Store.reset!()
    :ok
  end

  defp request(method, path, body \\ nil) do
    conn(method, path, body && JSON.encode!(body))
    |> then(&if(body, do: put_req_header(&1, "content-type", "application/json"), else: &1))
    |> put_req_header("authorization", "Bearer test-product-token")
    |> then(&Api.Router.call(&1, Api.Router.init([])))
  end

  defp decoded(conn), do: JSON.decode!(conn.resp_body)

  test "the HTTP answer for 422156 EQUALS the engine's direct answer" do
    envelope_map = @fixture |> File.read!() |> JSON.decode!()
    assert request(:post, "/v1/backfill/envelopes", %{envelopes: [envelope_map]}).status == 200

    # ── the engine, directly: same envelope, same finer fold, same permissive priority ─────────
    env = HistoryEnvelope.load!(@fixture)
    %{log: log, ledger: ledger} = FinerClaims.run([env])
    direct = History.now(log, Priority.new(%{}, []))
    direct_variants = direct |> Enum.flat_map(& &1.variants) |> Map.new(&{&1.key, &1})

    # ── the API's answer ────────────────────────────────────────────────────────────────────────
    body = decoded(request(:get, "/v1/products/422156"))
    key = body["key"]

    # identical fold => identical surrogate keys and memberships
    assert Map.has_key?(ledger.members, key)
    direct_variant = Map.fetch!(direct_variants, key)

    assert body["codes"] ==
             direct_variant.codes |> Enum.sort() |> Enum.map(fn {s, v} -> "#{s}:#{v}" end)

    # every attribute the engine resolves, the API serves with the same value and winner
    api_attrs = Map.new(body["attributes"], &{&1["field"], &1})

    for {field, decision} <- direct_variant.attributes do
      api = Map.fetch!(api_attrs, to_string(field))

      assert api["value"] == decision.value,
             "#{field}: API #{inspect(api["value"])} vs engine #{inspect(decision.value)}"

      assert api["status"] == to_string(decision.status)
    end

    assert Enum.any?(body["media"], &String.starts_with?(&1["asset"], "MED_"))

    # by-code agrees with the ledger: the product's CNK lands on the same key
    cnk = Enum.find(direct_variant.codes, &match?({:cnk, _}, &1))
    {:cnk, cnk_value} = cnk
    by_code = decoded(request(:get, "/v1/products/by-code/cnk/#{cnk_value}"))
    assert Enum.any?(by_code["products"], &(&1["key"] == key))
  end

  test "replaying the backfill is byte-identical; rebuild! confirms projections from zero" do
    envelope_map = @fixture |> File.read!() |> JSON.decode!()
    request(:post, "/v1/backfill/envelopes", %{envelopes: [envelope_map]})

    checkpoint = fn ->
      %{rows: [[offset, payload]]} =
        Postgrex.query!(
          Api.DB,
          ~s(SELECT "offset", payload::text FROM projection_checkpoints WHERE name = 'main'),
          []
        )

      {offset, payload}
    end

    before = checkpoint.()
    request(:post, "/v1/backfill/envelopes", %{envelopes: [envelope_map]})
    assert checkpoint.() == before, "a replayed envelope must not change the checkpoint"

    # the disposable-projection guarantee holds over the full realistic log
    assert {:ok, {:ok, offset}} = Api.Store.rebuild!()
    assert offset == elem(before, 0)
  end

  test "the change feed replays the whole story in order — claims, identity, legacy ids, the flag" do
    envelope_map = @fixture |> File.read!() |> JSON.decode!()
    request(:post, "/v1/backfill/envelopes", %{envelopes: [envelope_map]})

    feed = decoded(request(:get, "/v1/changes?since=0&limit=1000"))
    types = feed["events"] |> Enum.map(& &1["type"]) |> Enum.uniq()

    assert "claim" in types
    assert "minted" in types
    assert "legacy_id_assigned" in types
    # the 422156 convergence is in the feed as a PROPOSAL — never a silent merge
    assert "merge_proposal" in types
    refute "merged" in types

    offsets = Enum.map(feed["events"], & &1["offset"])
    assert offsets == Enum.sort(offsets)
  end
end
