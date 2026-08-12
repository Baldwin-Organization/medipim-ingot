defmodule Api.SourceRecordsTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  setup do
    {:ok, :ok} = Api.Store.reset!()
    :ok
  end

  defp request(method, path, body \\ nil) do
    conn(method, path, if(body, do: JSON.encode!(body), else: nil))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer test-product-token")
    |> then(&Api.Router.call(&1, Api.Router.init([])))
  end

  defp decoded(conn), do: JSON.decode!(conn.resp_body)

  defp claims(code \\ "cnk:1000001") do
    [
      %{kind: "identity", codes: [code]},
      %{kind: "attribute", code: code, field: "name", value: "Sunscreen"},
      %{kind: "grouping", code: code, product: 42},
      %{
        kind: "media",
        asset: "front",
        target: code,
        uri: "https://example.test/front.jpg",
        role: "primary"
      },
      %{kind: "edge", from: code, relation: "contains", to: "substance_id:water"}
    ]
  end

  defp revise(revision, body),
    do: request(:put, "/v1/source-records/supplier/P-1/revisions/#{revision}", body)

  test "replace owns the whole record while patch preserves facts it does not mention" do
    first = revise("1", %{operation: "replace", claims: claims()})
    assert first.status == 200
    first_body = decoded(first)
    assert first_body["status"] == "active"
    assert is_binary(first_body["key"])
    assert is_integer(first_body["legacy_id"])

    patch =
      revise("2", %{
        operation: "patch",
        base_revision: "1",
        upsert: [%{kind: "attribute", code: "cnk:1000001", field: "name", value: "Sun lotion"}]
      })

    assert patch.status == 200
    live = Api.State.current_claims(Api.Store.state())

    assert Enum.sort(Enum.map(live, & &1.kind)) == [
             :attribute,
             :edge,
             :grouping,
             :identity,
             :media
           ]

    assert Enum.find(live, &(&1.kind == :attribute)).data.value == "Sun lotion"

    replace =
      revise("3", %{
        operation: "replace",
        base_revision: "2",
        claims: [%{kind: "identity", codes: ["cnk:1000001"]}]
      })

    assert replace.status == 200
    assert [%Events.ClaimAsserted{kind: :identity}] = Api.State.current_claims(Api.Store.state())
  end

  test "patch explicitly removes one media fact and leaves attributes and edges" do
    assert revise("1", %{operation: "replace", claims: claims()}).status == 200

    response =
      revise("2", %{
        operation: "patch",
        base_revision: "1",
        remove: [%{kind: "media", asset: "front", target: "cnk:1000001"}]
      })

    assert response.status == 200
    kinds = Api.State.current_claims(Api.Store.state()) |> Enum.map(& &1.kind)
    refute :media in kinds
    assert :attribute in kinds
    assert :edge in kinds
  end

  test "withdraw removes every contribution and reactivate reuses key and legacy id with new codes" do
    first = revise("1", %{operation: "replace", claims: claims()}) |> decoded()
    original_key = first["key"]
    original_legacy_id = first["legacy_id"]

    withdrawn = revise("2", %{operation: "withdraw", base_revision: "1"})
    assert withdrawn.status == 200
    assert decoded(withdrawn)["status"] == "withdrawn"
    assert Api.State.current_claims(Api.Store.state()) == []
    assert Api.Store.state().ledger.members == %{}

    read_withdrawn = request(:get, "/v1/source-records/supplier/P-1") |> decoded()
    assert read_withdrawn["status"] == "withdrawn"
    assert read_withdrawn["key"] == original_key
    assert read_withdrawn["legacy_id"] == original_legacy_id

    withdrawn_product = request(:get, "/v1/products/#{original_legacy_id}") |> decoded()
    assert withdrawn_product["status"] == "withdrawn"

    reactivated =
      revise("3", %{
        operation: "reactivate",
        base_revision: "2",
        claims: claims("cnk:2000002")
      })

    body = decoded(reactivated)
    assert body["key"] == original_key
    assert body["legacy_id"] == original_legacy_id

    assert Map.fetch!(Api.Store.state().ledger.members, original_key) ==
             MapSet.new([{:cnk, "2000002"}])
  end

  test "revision replay is a no-op and stale or conflicting writes are rejected atomically" do
    body = %{operation: "replace", valid_from: "2026-07-10", claims: claims()}
    assert revise("1", body).status == 200
    log = Api.Store.log()

    replay = revise("1", body)
    assert replay.status == 200
    assert decoded(replay)["replayed"] == true
    assert Api.Store.log() == log

    conflict =
      revise("1", %{operation: "replace", valid_from: "2026-07-10", claims: claims("cnk:2000002")})

    assert conflict.status == 409
    assert Api.Store.log() == log

    stale = revise("2", %{operation: "patch", base_revision: "stale", upsert: []})
    assert stale.status == 412
    assert Api.Store.log() == log
  end

  test "rebuilding from the event log reproduces records, tombstones, and key bindings" do
    assert revise("1", %{operation: "replace", claims: claims()}).status == 200
    assert revise("2", %{operation: "withdraw", base_revision: "1"}).status == 200
    before = Api.Store.state()

    assert {:ok, _offset} = Api.Store.rebuild!()
    assert Api.Store.state() == before
  end

  test "withdrawing one supporting record keeps the shared key and flags the lost evidence" do
    first =
      request(:put, "/v1/source-records/source-a/A/revisions/1", %{
        operation: "replace",
        claims: [%{kind: "identity", codes: ["cnk:1000001"]}]
      })
      |> decoded()

    second =
      request(:put, "/v1/source-records/source-b/B/revisions/1", %{
        operation: "replace",
        claims: [%{kind: "identity", codes: ["cnk:1000001"]}]
      })
      |> decoded()

    assert second["key"] == first["key"]

    response =
      request(:put, "/v1/source-records/source-a/A/revisions/2", %{
        operation: "withdraw",
        base_revision: "1"
      })

    assert response.status == 200
    assert Map.has_key?(Api.Store.state().ledger.members, first["key"])

    assert Enum.any?(Api.State.open_flags(Api.Store.state()), fn flag ->
             flag.subject == {:source_withdrew, first["key"]}
           end)
  end

  test "withdrawn key numbers are not reused by unrelated records" do
    first = revise("1", %{operation: "replace", claims: claims()}) |> decoded()
    assert first["key"] == "SK_1"
    assert revise("2", %{operation: "withdraw", base_revision: "1"}).status == 200

    second =
      request(:put, "/v1/source-records/supplier/P-2/revisions/1", %{
        operation: "replace",
        claims: [%{kind: "identity", codes: ["cnk:2000002"]}]
      })
      |> decoded()

    assert second["key"] == "SK_2"
  end
end
