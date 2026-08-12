# Scaffold contract tests (bead gr-0de): health, the two-token separation, and the second-port
# split. Endpoints themselves land with their own beads — here the surfaces 404 once authorized.

defmodule Api.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @product "test-product-token"
  @steward "test-steward-token"

  setup do
    {:ok, :ok} = Api.Store.reset!()
    :ok
  end

  defp call(router, conn), do: router.call(conn, router.init([]))
  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  describe "GET /health" do
    test "is an unauthenticated process-liveness check" do
      conn = call(Api.Router, conn(:get, "/health"))
      assert conn.status == 200
      assert %{"status" => "ok"} = JSON.decode!(conn.resp_body)
      assert [request_id] = get_resp_header(conn, "x-request-id")
      assert byte_size(request_id) > 0
    end

    test "readiness checks the migrated database and reports projection lag" do
      conn = call(Api.Router, conn(:get, "/ready"))
      assert conn.status == 200

      assert %{
               "status" => "ready",
               "db" => true,
               "event_offset" => offset,
               "projection_offset" => offset
             } = JSON.decode!(conn.resp_body)
    end

    test "readiness rejects a projection checkpoint behind the event log" do
      claim =
        Substrate.claim(
          :router_test,
          :identity,
          %{ref: "lag", codes: [{:cnk, "111"}]},
          ~D[2026-03-01],
          ~D[2026-03-01]
        )

      assert {:ok, :ok} =
               Api.Store.append(fn _state, _conn -> {:ok, [claim], :ok} end)

      Postgrex.query!(
        Api.DB,
        "UPDATE projection_checkpoints SET \"offset\" = 0 WHERE name = 'main'",
        []
      )

      response = call(Api.Router, conn(:get, "/ready"))
      assert response.status == 503

      assert %{
               "status" => "not_ready",
               "db" => true,
               "event_offset" => 1,
               "projection_offset" => 0
             } = JSON.decode!(response.resp_body)
    end
  end

  describe "token separation" do
    test "the Product surface requires the product token" do
      assert call(Api.Router, conn(:get, "/v1/anything")).status == 401

      conn = conn(:get, "/v1/anything") |> bearer(@product)
      assert call(Api.Router, conn).status == 404
    end

    test "a steward token does NOT open the Product surface" do
      conn = conn(:get, "/v1/anything") |> bearer(@steward)
      assert call(Api.Router, conn).status == 401
    end

    test "the Steward surface requires the steward token" do
      assert call(Api.Router, conn(:get, "/steward/v1/queue")).status == 401

      conn = conn(:get, "/steward/v1/queue") |> bearer(@steward)
      assert call(Api.Router, conn).status == 200
    end

    test "a product token does NOT open the Steward surface" do
      conn = conn(:get, "/steward/v1/queue") |> bearer(@product)
      assert call(Api.Router, conn).status == 401
    end

    test "a malformed authorization header is rejected" do
      conn = conn(:get, "/v1/anything") |> put_req_header("authorization", @product)
      assert call(Api.Router, conn).status == 401
    end
  end

  describe "second-port separation" do
    test "the public router does not serve /steward at all, even with a valid token" do
      conn = conn(:get, "/steward/v1/queue") |> bearer(@steward)
      assert call(Api.PublicRouter, conn).status == 404
    end

    test "the steward site serves /steward and health, but not /v1" do
      conn = conn(:get, "/steward/v1/queue") |> bearer(@steward)
      assert call(Api.StewardSite, conn).status == 200

      assert call(Api.StewardSite, conn(:get, "/health")).status == 200

      conn = conn(:get, "/v1/products/1") |> bearer(@product)
      assert call(Api.StewardSite, conn).status == 404
    end
  end

  test "unknown paths 404 with a JSON body" do
    conn = call(Api.Router, conn(:get, "/nope"))
    assert conn.status == 404
    assert %{"error" => "not found"} = JSON.decode!(conn.resp_body)
  end
end
