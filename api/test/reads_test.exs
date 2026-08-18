# Product API reads (bead gr-uii), end to end: products by legacy id (the backwards-compatible
# read), by-code with canonicalization, as-of time travel from the log, the change feed, and
# legacy-id continuity across a merge. async: false — shared tables.

alias GoldenRecord.{Substrate, Cluster, IdentityLedger, Stewardship}

defmodule Api.ReadsTest do
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

  defp seed_two_products do
    request(:post, "/v1/claims", %{
      claims: [
        %{
          kind: "identity",
          source: "medipim",
          ref: "P-1",
          codes: ["cnk:1000001", "gtin:05012345678900"]
        },
        %{
          kind: "attribute",
          source: "medipim",
          code: "cnk:1000001",
          field: "name",
          value: "Sunscreen"
        },
        %{
          kind: "media",
          source: "medipim",
          asset: "IMG-1",
          target: "cnk:1000001",
          role: "primary",
          uri: "cdn://a"
        },
        %{kind: "identity", source: "medipim", ref: "P-2", codes: ["cnk:1000002"]}
      ]
    })

    Api.Store.state()
  end

  defp seed_two_products_on(date) do
    claims = [
      Substrate.claim(
        "medipim",
        :identity,
        %{ref: "P-1", codes: [{:cnk, "1000001"}]},
        date,
        date
      ),
      Substrate.claim("medipim", :identity, %{ref: "P-2", codes: [{:cnk, "1000002"}]}, date, date)
    ]

    identity_events =
      IdentityLedger.decide(
        IdentityLedger.new(),
        {:reconcile, Cluster.variants(Substrate.current(claims)), MapSet.new(), date}
      )

    ledger = Enum.reduce(identity_events, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1))
    assignments = LegacyIds.decide(ledger.members, claims, %{}, date)

    {:ok, :ok} =
      Api.Store.append(fn _state, _conn ->
        {:ok, claims ++ identity_events ++ assignments, :ok}
      end)

    Api.Store.state()
  end

  describe "GET /v1/products/{legacy_id}" do
    test "answers with codes, attributes (provenance), media, and status" do
      state = seed_two_products()

      {key, id} =
        Enum.find(state.assigned, fn {k, _} ->
          map_size(state.ledger.members[k]) > 0 and
            MapSet.member?(state.ledger.members[k], {:cnk, "1000001"})
        end)

      conn = request(:get, "/v1/products/#{id}")
      assert conn.status == 200
      body = decoded(conn)

      assert body["legacy_id"] == id
      assert body["key"] == key
      assert body["status"] == "active"
      assert "cnk:1000001" in body["codes"]
      assert "gtin:05012345678900" in body["codes"]

      assert [%{"field" => "name", "value" => "Sunscreen", "winner" => "medipim"}] =
               body["attributes"]

      assert [%{"asset" => "dam:IMG-1", "uri" => "cdn://a"}] = body["media"]
      assert body["merged_from"] == nil
    end

    test "unknown legacy id and non-integer ids 404" do
      assert request(:get, "/v1/products/999999").status == 404
      assert request(:get, "/v1/products/abc").status == 404
    end

    test "an absorbed key's legacy id keeps answering — followed to the survivor" do
      state = seed_two_products()
      [k1, k2] = state.ledger.members |> Map.keys() |> Enum.sort()
      absorbed_id = state.assigned[k2]

      {:ok, _} =
        Api.Store.append(fn st, _conn ->
          {:ok, Stewardship.approve_merge(st.ledger.members, [k1, k2], :sam, Date.utc_today()),
           :ok}
        end)

      conn = request(:get, "/v1/products/#{absorbed_id}")
      assert conn.status == 200
      body = decoded(conn)
      assert body["key"] == k1
      assert body["merged_from"] == k2
      assert body["status"] == "active"
    end
  end

  describe "GET /v1/products/by-code/{scheme}/{code}" do
    test "finds by any spelling of the code — canonicalization applies" do
      seed_two_products()

      # the EAN-13 spelling of the stored GTIN-14
      conn = request(:get, "/v1/products/by-code/ean/5012345678900")
      assert conn.status == 200
      body = decoded(conn)
      assert body["code"] == "gtin:05012345678900"
      assert [%{"codes" => codes}] = body["products"]
      assert "cnk:1000001" in codes
    end

    test "404 when no product carries the code" do
      seed_two_products()
      assert request(:get, "/v1/products/by-code/cnk/7777777").status == 404
    end
  end

  describe "GET /v1/products/{legacy_id}?as_of= — the real fixture" do
    test "before its first identity date the product is honestly not resolvable; later it is" do
      envelope = @fixture |> File.read!() |> JSON.decode!()
      request(:post, "/v1/backfill/envelopes", %{envelopes: [envelope]})

      conn = request(:get, "/v1/products/422156?as_of=2017-01-01")
      assert conn.status == 404
      assert %{"as_of" => "2017-01-01"} = decoded(conn)

      conn = request(:get, "/v1/products/422156?as_of=2026-05-01")
      assert conn.status == 200
      assert %{"as_of" => "2026-05-01", "legacy_id" => 422_156} = decoded(conn)

      assert request(:get, "/v1/products/422156?as_of=nonsense").status == 422
    end

    test "an absorbed legacy id follows only after the merge date" do
      d1 = Date.add(Date.utc_today(), -10)
      d2 = Date.add(Date.utc_today(), -5)
      state = seed_two_products_on(d1)
      [k1, k2] = state.ledger.members |> Map.keys() |> Enum.sort()
      absorbed_id = state.assigned[k2]

      {:ok, _} =
        Api.Store.append(fn st, _conn ->
          {:ok, Stewardship.approve_merge(st.ledger.members, [k1, k2], :sam, d2), :ok}
        end)

      before = decoded(request(:get, "/v1/products/#{absorbed_id}?as_of=#{Date.to_iso8601(d1)}"))
      assert before["key"] == k2

      after_merge =
        decoded(request(:get, "/v1/products/#{absorbed_id}?as_of=#{Date.to_iso8601(d2)}"))

      assert after_merge["key"] == k1
    end
  end

  describe "GET /v1/changes" do
    test "streams decoded events after a cursor, with the next cursor" do
      seed_two_products()

      conn = request(:get, "/v1/changes?since=0&limit=3")
      body = decoded(conn)
      assert body["count"] == 3
      assert [%{"offset" => 1, "type" => "claim"} | _] = body["events"]

      conn = request(:get, "/v1/changes?since=#{body["next"]}")
      rest = decoded(conn)
      assert Enum.any?(rest["events"], &(&1["type"] == "minted"))
      assert Enum.any?(rest["events"], &(&1["type"] == "legacy_id_assigned"))

      conn = request(:get, "/v1/changes?since=#{rest["next"]}")
      assert decoded(conn)["count"] == 0
    end

    test "bad cursors 422" do
      assert request(:get, "/v1/changes?since=-1").status == 422
      assert request(:get, "/v1/changes?since=abc").status == 422
    end
  end
end
