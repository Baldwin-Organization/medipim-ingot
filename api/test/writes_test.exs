# Product API writes (bead gr-qqy), end to end through the router: live claims reconcile
# fold-forward against the threaded ledger, backfill folds the REAL 422156 fixture finer-grained
# and is idempotent, validation rejects whole batches, and a live bridge between established keys
# is FLAGGED — never auto-merged. async: false — shared tables, truncated per test.

defmodule Api.WritesTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @fixture Path.expand("../../test/ingest/fixtures/medipim_be_422156.json", __DIR__)

  setup do
    {:ok, :ok} = Api.Store.reset!()
    :ok
  end

  defp post!(path, body) do
    conn(:post, path, JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer test-product-token")
    |> then(&Api.Router.call(&1, Api.Router.init([])))
  end

  defp post_with_key!(path, body, key) do
    conn(:post, path, JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer test-product-token")
    |> put_req_header("idempotency-key", key)
    |> then(&Api.Router.call(&1, Api.Router.init([])))
  end

  defp decoded(conn), do: JSON.decode!(conn.resp_body)

  describe "POST /v1/claims — live claims" do
    test "batches over the configured claim limit are rejected before writing" do
      old = Application.get_env(:golden_record_api, :max_claims)
      Application.put_env(:golden_record_api, :max_claims, 1)
      on_exit(fn -> Application.put_env(:golden_record_api, :max_claims, old) end)

      conn =
        post!("/v1/claims", %{
          claims: [
            %{kind: "identity", source: "m", ref: "A", codes: ["cnk:1"]},
            %{kind: "identity", source: "m", ref: "B", codes: ["cnk:2"]}
          ]
        })

      assert conn.status == 413
      assert decoded(conn)["error"] =~ "claim limit"
      assert Api.Store.log() == []
    end

    test "two new products: minted keys, legacy ids allocated, claims in the log" do
      conn =
        post!("/v1/claims", %{
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
            %{kind: "identity", source: "medipim", ref: "P-2", codes: ["cnk:1000002"]}
          ]
        })

      assert conn.status == 200
      body = decoded(conn)
      assert body["accepted"] == 3
      assert body["flagged"] == []
      assert Enum.count(body["events"], &(&1["type"] == "minted")) == 2

      state = Api.Store.state()
      assert map_size(state.ledger.members) == 2
      # every key got a legacy id, freshly allocated (no grouping evidence)
      assert map_size(state.assigned) == 2
      assert state.assigned |> Map.values() |> Enum.uniq() |> length() == 2
    end

    test "an invalid claim rejects the WHOLE batch with its index; nothing enters the log" do
      conn =
        post!("/v1/claims", %{
          claims: [
            %{kind: "identity", source: "medipim", ref: "OK", codes: ["cnk:1000001"]},
            %{kind: "attribute", source: "medipim", code: "not-a-code", field: "name", value: "x"}
          ]
        })

      assert conn.status == 422
      assert [%{"index" => 1}] = decoded(conn)["errors"]
      assert Api.Store.log() == []
    end

    test "codes parse engine-native schemes; GTIN family canonicalizes; unknown schemes pass through" do
      post!("/v1/claims", %{
        claims: [
          %{kind: "identity", source: "m", ref: "X", codes: ["ean:5012345678900", "mystery:42"]}
        ]
      })

      [claim] = Api.State.current_claims(Api.Store.state())
      assert {:gtin, "05012345678900"} in claim.data.codes
      assert {"mystery", "42"} in claim.data.codes
    end

    test "accepted claims return validator warnings" do
      conn =
        post!("/v1/claims", %{
          claims: [
            %{kind: "identity", source: "m", ref: "X", codes: ["cnk:3612174", "mystery:42"]}
          ]
        })

      assert conn.status == 200
      warnings = decoded(conn)["warnings"]
      assert length(warnings) == 2
      assert Enum.any?(warnings, &(&1["error"] =~ "CNK Mod-10"))
      assert Enum.any?(warnings, &(&1["error"] =~ "unknown scheme"))
    end

    test "a later claim re-asserting the same listing GROWS the key (members changed, same key)" do
      post!("/v1/claims", %{
        claims: [%{kind: "identity", source: "m", ref: "X", codes: ["cnk:1000001"]}]
      })

      [key] = Api.Store.state().ledger.members |> Map.keys()

      conn =
        post!("/v1/claims", %{
          claims: [
            %{
              kind: "identity",
              source: "m",
              ref: "X",
              codes: ["cnk:1000001", "gtin:05012345678900"]
            }
          ]
        })

      body = decoded(conn)
      assert [%{"type" => "members_changed", "key" => ^key}] = body["events"]
      assert map_size(Api.Store.state().ledger.members) == 1
    end

    test "resubmitting the SAME batch is idempotent: nothing appended, no state churn" do
      batch = %{
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
          }
        ]
      }

      assert post!("/v1/claims", batch).status == 200
      log = Api.Store.log()
      state = Api.Store.state()

      conn = post!("/v1/claims", batch)
      assert conn.status == 200
      body = decoded(conn)
      assert body["accepted"] == 0
      assert body["skipped"] == 2
      assert body["claims"] == 0
      assert body["events"] == []

      assert Api.Store.log() == log
      assert Api.Store.state() == state
    end

    test "an Idempotency-Key replays the original response without appending" do
      batch = %{claims: [%{kind: "identity", source: "m", ref: "A", codes: ["cnk:1"]}]}

      first = post_with_key!("/v1/claims", batch, "batch-1")
      assert first.status == 200
      first_body = decoded(first)
      log = Api.Store.log()

      second = post_with_key!("/v1/claims", batch, "batch-1")
      assert second.status == 200
      assert decoded(second) == first_body
      assert Api.Store.log() == log
    end

    test "reusing an Idempotency-Key with different claims rejects without appending" do
      first = %{claims: [%{kind: "identity", source: "m", ref: "A", codes: ["cnk:1"]}]}
      changed = %{claims: [%{kind: "identity", source: "m", ref: "B", codes: ["cnk:2"]}]}

      assert post_with_key!("/v1/claims", first, "batch-1").status == 200
      log = Api.Store.log()

      conn = post_with_key!("/v1/claims", changed, "batch-1")
      assert conn.status == 409
      assert decoded(conn)["error"] =~ "idempotency"
      assert Api.Store.log() == log
    end

    test "an overlapping batch appends ONLY the new claims" do
      post!("/v1/claims", %{
        claims: [%{kind: "identity", source: "m", ref: "A", codes: ["cnk:1000001"]}]
      })

      conn =
        post!("/v1/claims", %{
          claims: [
            # identical content — its slot already holds this claim, so it is skipped
            %{kind: "identity", source: "m", ref: "A", codes: ["cnk:1000001"]},
            %{kind: "identity", source: "m", ref: "B", codes: ["cnk:1000002"]}
          ]
        })

      assert conn.status == 200
      body = decoded(conn)
      assert body["accepted"] == 1
      assert body["skipped"] == 1
      assert body["claims"] == 1
      assert Enum.count(body["events"], &(&1["type"] == "minted")) == 1

      # each listing's claim is in the log exactly once
      claim_events = for %Events.ClaimAsserted{} = e <- Api.Store.log(), do: e
      assert length(claim_events) == 2
      assert map_size(Api.Store.state().ledger.members) == 2
    end

    test "same slot twice in one batch resolves last-wins, even when the last value equals pre-batch state" do
      # establish the slot at value X
      post!("/v1/claims", %{
        claims: [
          %{kind: "identity", source: "m", ref: "X", codes: ["cnk:1000001"]},
          %{kind: "attribute", source: "m", code: "cnk:1000001", field: "name", value: "X"}
        ]
      })

      # a batch that asserts the SAME slot twice: Y, then X (X equals the pre-batch state).
      # asserted? against transaction-start state would mis-skip the trailing X and let Y win;
      # threading the in-batch view keeps both, so last-wins settles on X.
      conn =
        post!("/v1/claims", %{
          claims: [
            %{kind: "attribute", source: "m", code: "cnk:1000001", field: "name", value: "Y"},
            %{kind: "attribute", source: "m", code: "cnk:1000001", field: "name", value: "X"}
          ]
        })

      assert conn.status == 200

      # exactly one live name claim, and last-wins settled it on X (not the mis-skipped Y)
      name_claims =
        for {_slot, %{kind: :attribute, data: %{field: "name"}} = c} <- Api.Store.state().current,
            do: c.data.value

      assert name_claims == ["X"]
    end

    test "a live bridge between two ESTABLISHED keys is flagged, never merged" do
      post!("/v1/claims", %{
        claims: [
          %{kind: "identity", source: "m", ref: "A", codes: ["cnk:1000001"]},
          %{kind: "identity", source: "m", ref: "B", codes: ["gtin:05012345678900"]}
        ]
      })

      conn =
        post!("/v1/claims", %{
          claims: [
            %{
              kind: "identity",
              source: "mkt",
              ref: "K",
              codes: ["cnk:1000001", "gtin:05012345678900"]
            }
          ]
        })

      body = decoded(conn)
      assert [%{"type" => "merge_proposal", "keys" => keys}] = body["flagged"]
      assert length(keys) == 2

      state = Api.Store.state()
      assert map_size(state.ledger.members) == 2
      assert [%Events.ConflictFlagged{}] = Api.State.open_flags(state)
    end
  end

  describe "POST /v1/backfill/envelopes — the real fixture" do
    test "422156 backfills finer-grained: two live keys, the gated proposal, legacy id continuity" do
      envelope = @fixture |> File.read!() |> JSON.decode!()
      conn = post!("/v1/backfill/envelopes", %{envelopes: [envelope]})

      assert conn.status == 200
      body = decoded(conn)
      assert body["accepted"] == 1
      assert body["skipped"] == 0
      # the convergence is GATED — the over-merge guard's standing proposal survives the API
      assert [%{"type" => "merge_proposal"}] = body["flagged"]

      state = Api.Store.state()
      # one key inherited the legacy entity; every key has SOME legacy id
      assert 422_156 in Map.values(state.assigned)

      product_keys =
        Enum.count(state.ledger.members, fn {key, _} -> Lanes.lane_of_key(key) == :product end)

      assert map_size(state.assigned) == product_keys
      assert map_size(state.assigned) < map_size(state.ledger.members)
    end

    test "replaying the same envelope is a NO-OP (idempotent)" do
      envelope = @fixture |> File.read!() |> JSON.decode!()
      post!("/v1/backfill/envelopes", %{envelopes: [envelope]})
      log_size = length(Api.Store.log())

      conn = post!("/v1/backfill/envelopes", %{envelopes: [envelope]})
      body = decoded(conn)
      assert body["accepted"] == 0
      assert body["skipped"] == 1
      assert length(Api.Store.log()) == log_size
    end

    test "a malformed envelope rejects the whole batch" do
      good = @fixture |> File.read!() |> JSON.decode!()
      conn = post!("/v1/backfill/envelopes", %{envelopes: [good, %{"nope" => true}]})

      assert conn.status == 422
      assert [%{"index" => 1}] = decoded(conn)["errors"]
      assert Api.Store.log() == []
    end

    test "a post-backfill NEW product allocates a legacy id ABOVE the backfilled ones" do
      envelope = @fixture |> File.read!() |> JSON.decode!()
      post!("/v1/backfill/envelopes", %{envelopes: [envelope]})

      post!("/v1/claims", %{
        claims: [%{kind: "identity", source: "medipim", ref: "NEW-1", codes: ["cnk:9999999"]}]
      })

      state = Api.Store.state()
      new_key = state.assigned |> Enum.max_by(fn {_k, id} -> id end) |> elem(0)
      assert state.assigned[new_key] > 422_156
      assert state.ledger.members[new_key] == MapSet.new([{:cnk, "9999999"}])
    end
  end
end
