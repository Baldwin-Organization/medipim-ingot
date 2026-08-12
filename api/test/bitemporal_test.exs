defmodule Api.BitemporalTest do
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

  defp revise(revision, body),
    do: request(:put, "/v1/source-records/supplier/P-1/revisions/#{revision}", body)

  defp document(name, code \\ "cnk:1000001") do
    [
      %{kind: "identity", codes: [code]},
      %{kind: "attribute", code: code, field: "name", value: name}
    ]
  end

  defp product(id, params \\ %{}) do
    query = if map_size(params) == 0, do: "", else: "?" <> URI.encode_query(params)
    request(:get, "/v1/products/#{id}#{query}")
  end

  defp name(body) do
    body["attributes"]
    |> Enum.find(&(&1["field"] == "name"))
    |> Map.fetch!("value")
  end

  test "a future revision is stored now but does not appear before its effective date" do
    today = Date.utc_today()
    future = Date.add(today, 30)

    first =
      revise("1", %{
        operation: "replace",
        valid_from: Date.to_iso8601(Date.add(today, -30)),
        claims: document("Old")
      })
      |> decoded()

    second =
      revise("2", %{
        operation: "replace",
        base_revision: "1",
        valid_from: Date.to_iso8601(future),
        claims: document("Future")
      })
      |> decoded()

    assert name(product(first["legacy_id"]) |> decoded()) == "Old"

    at_future =
      product(first["legacy_id"], %{"effective_at" => Date.to_iso8601(future)})
      |> decoded()

    assert name(at_future) == "Future"

    known_before_future =
      product(first["legacy_id"], %{
        "known_at" => first["recorded_at"],
        "effective_at" => Date.to_iso8601(future)
      })
      |> decoded()

    assert name(known_before_future) == "Old"
    assert second["recorded_at"] > first["recorded_at"]
  end

  test "a late bounded correction changes later knowledge only and expires at valid_to" do
    first =
      revise("1", %{
        operation: "replace",
        valid_from: "2026-01-01",
        claims: document("Original")
      })
      |> decoded()

    correction =
      revise("2", %{
        operation: "replace",
        base_revision: "1",
        valid_from: "2026-02-01",
        valid_to: "2026-02-10",
        claims: document("Corrected")
      })
      |> decoded()

    before_receipt =
      product(first["legacy_id"], %{
        "known_at" => first["recorded_at"],
        "effective_at" => "2026-02-05"
      })
      |> decoded()

    after_receipt =
      product(first["legacy_id"], %{
        "known_at" => correction["recorded_at"],
        "effective_at" => "2026-02-05"
      })
      |> decoded()

    after_interval =
      product(first["legacy_id"], %{
        "known_at" => correction["recorded_at"],
        "effective_at" => "2026-02-10"
      })
      |> decoded()

    assert name(before_receipt) == "Original"
    assert name(after_receipt) == "Corrected"
    assert name(after_interval) == "Original"
  end

  test "bounded withdrawal hides a record only inside its effective interval" do
    first =
      revise("1", %{operation: "replace", valid_from: "2026-01-01", claims: document("Original")})
      |> decoded()

    withdrawal =
      revise("2", %{
        operation: "withdraw",
        base_revision: "1",
        valid_from: "2026-03-01",
        valid_to: "2026-03-10"
      })
      |> decoded()

    inside =
      product(first["legacy_id"], %{
        "known_at" => withdrawal["recorded_at"],
        "effective_at" => "2026-03-05"
      })

    after_interval =
      product(first["legacy_id"], %{
        "known_at" => withdrawal["recorded_at"],
        "effective_at" => "2026-03-10"
      })

    assert inside.status == 200
    assert decoded(inside)["status"] == "withdrawn"
    assert name(decoded(after_interval)) == "Original"
  end

  test "server timestamps are durable and invalid intervals or clocks are rejected" do
    response =
      revise("1", %{operation: "replace", valid_from: "2026-01-01", claims: document("Original")})

    assert response.status == 200
    recorded_at = decoded(response)["recorded_at"]
    assert {:ok, _, _} = DateTime.from_iso8601(recorded_at)

    %{rows: [[database_time, payload]]} =
      Postgrex.query!(
        Api.DB,
        "SELECT recorded_at, payload::text FROM events WHERE type = 'SourceRecordRevised'",
        []
      )

    event = Api.Codec.decode!(payload)
    assert database_time == event.recorded_at

    invalid =
      revise("2", %{
        operation: "replace",
        base_revision: "1",
        valid_from: "2026-04-10",
        valid_to: "2026-04-10",
        claims: document("Bad")
      })

    assert invalid.status == 422
    assert decoded(invalid)["error"] =~ "valid_to"

    assert product(1, %{"known_at" => "yesterday"}).status == 422
    assert product(1, %{"effective_at" => "soon"}).status == 422
  end

  test "an old revision still replays exactly after newer revisions exist" do
    old = %{operation: "replace", valid_from: "2026-01-01", claims: document("Old")}
    assert revise("1", old).status == 200

    assert revise("2", %{
             operation: "replace",
             base_revision: "1",
             valid_from: "2026-02-01",
             claims: document("New")
           }).status == 200

    log = Api.Store.log()
    replay = revise("1", old)
    assert replay.status == 200
    assert decoded(replay)["replayed"] == true
    assert Api.Store.log() == log
  end
end
