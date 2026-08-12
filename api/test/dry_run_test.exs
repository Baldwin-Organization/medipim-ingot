# POST /v1/dry-run (bead gr-rlq), end to end through the router: the full pipeline runs
# uncommitted and answers with the migration report. Pinned here: (a) a dry-run commits NOTHING
# (events + projections byte-identical), (b) dry-run-then-submit coherence — the verdicts a dry-run
# predicts are exactly what a real POST /v1/claims of the same batch produces, (c) the report
# sections and counts on a contrived batch with a known conflict, merge candidate, code collision
# and mint, (d) the product token gates the endpoint. async: false — shared tables.

defmodule Api.DryRunTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  setup do
    {:ok, :ok} = Api.Store.reset!()
    :ok
  end

  defp post!(path, body, token \\ "test-product-token") do
    conn(:post, path, JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> then(&Api.Router.call(&1, Api.Router.init([])))
  end

  defp decoded(conn), do: JSON.decode!(conn.resp_body)

  # Two established products with one attribute and one grouping vote — the ground the dry-run
  # batches below collide with.
  defp establish! do
    conn =
      post!("/v1/claims", %{
        claims: [
          %{kind: "identity", source: "m", ref: "P-1", codes: ["cnk:1000001"]},
          %{
            kind: "attribute",
            source: "m",
            code: "cnk:1000001",
            field: "name",
            value: "Sunscreen"
          },
          %{kind: "grouping", source: "m", code: "cnk:1000001", product: 100},
          %{kind: "identity", source: "m", ref: "P-2", codes: ["cnk:1000002"]}
        ]
      })

    assert conn.status == 200
  end

  # One batch that exercises every report section: a bridge between the two established keys
  # (merge candidate), a contradicting attribute (conflict), a second product for an owned code
  # (code collision), and a brand-new listing (mint).
  @probe %{
    claims: [
      %{kind: "identity", source: "other", ref: "K", codes: ["cnk:1000001", "cnk:1000002"]},
      %{
        kind: "attribute",
        source: "other",
        code: "cnk:1000001",
        field: "name",
        value: "Sun Screen"
      },
      %{kind: "grouping", source: "other", code: "cnk:1000001", product: 200},
      %{kind: "identity", source: "other", ref: "P-9", codes: ["cnk:1000009"]}
    ]
  }

  describe "POST /v1/dry-run — commits nothing" do
    test "events and checkpoints are byte-identical after the call; state unchanged" do
      establish!()

      tables = fn ->
        %{rows: events} =
          Postgrex.query!(
            Api.DB,
            ~s(SELECT "offset", type, recorded_at, payload::text FROM events ORDER BY "offset"),
            []
          )

        %{rows: checkpoints} =
          Postgrex.query!(
            Api.DB,
            ~s(SELECT name, "offset", payload::text FROM projection_checkpoints),
            []
          )

        {events, checkpoints}
      end

      before_tables = tables.()
      before_state = Api.Store.state()

      conn = post!("/v1/dry-run", @probe)
      assert conn.status == 200
      assert decoded(conn)["would_commit"] == true

      assert tables.() == before_tables
      assert Api.Store.state() == before_state
    end
  end

  describe "POST /v1/dry-run — dry-run-then-submit coherence" do
    test "the predicted submission IS the real /v1/claims response for the same batch" do
      establish!()

      dry = decoded(post!("/v1/dry-run", @probe))
      real = post!("/v1/claims", @probe)

      assert real.status == 200
      assert dry["submission"] == decoded(real)

      # and the committed world agrees with the report's identity verdicts
      state = Api.Store.state()
      assert dry["counts"]["mints"] == 1
      assert map_size(state.ledger.members) == 3

      assert %Events.ConflictFlagged{subject: {:merge, keys}} =
               Enum.find(Api.State.open_flags(state), &match?({:merge, _}, &1.subject))

      assert [%{"keys" => ^keys}] = dry["merge_candidates"]
    end

    test "an invalid batch: the report carries the SAME per-index errors /v1/claims rejects with" do
      batch = %{
        claims: [
          %{kind: "identity", source: "m", ref: "OK", codes: ["cnk:1000001"]},
          %{kind: "attribute", source: "m", code: "not-a-code", field: "name", value: "x"}
        ]
      }

      dry = decoded(post!("/v1/dry-run", batch))
      real = post!("/v1/claims", batch)

      assert real.status == 422
      assert dry["would_commit"] == false
      assert dry["validation"]["errors"] == decoded(real)["errors"]
      assert dry["counts"]["validation_errors"] == 1
      assert dry["submission"] == nil
      assert Api.Store.log() == []
    end

    test "replaying an already-committed batch predicts the all-skipped no-op" do
      establish!()
      post!("/v1/claims", @probe)

      dry = decoded(post!("/v1/dry-run", @probe))
      real = decoded(post!("/v1/claims", @probe))

      assert dry["submission"] == real
      assert dry["counts"]["accepted"] == 0
      assert dry["counts"]["skipped"] == 4

      # nothing new — but the standing queue is still reported (the report reads the would-be state)
      assert [%{"new" => false}] = dry["merge_candidates"]
    end
  end

  describe "POST /v1/dry-run — the report" do
    test "sections present and counted on a batch with a known conflict + merge candidate" do
      establish!()

      body = decoded(post!("/v1/dry-run", @probe))

      assert body["dry_run"] == true
      assert body["would_commit"] == true
      assert body["validation"] == %{"errors" => []}

      assert body["counts"] == %{
               "claims" => 4,
               "accepted" => 4,
               "skipped" => 0,
               "validation_errors" => 0,
               "mints" => 1,
               "conflicts" => 1,
               "conflicts_by_field" => %{"name" => 1},
               "merge_candidates" => 1,
               "suspect_merge_candidates" => 0,
               "code_collisions" => 1,
               "steward_queue" => 3
             }

      # would-be mint: the new listing, keyed AFTER the two established keys
      assert [%{"key" => "SK_3", "codes" => ["cnk:1000009"]}] = body["mints"]

      # the merge candidate: both links national-grade — gated but NOT suspect, raised by THIS batch
      assert [candidate] = body["merge_candidates"]
      assert candidate["keys"] == ["SK_1", "SK_2"]
      assert candidate["suspect"] == false
      assert candidate["new"] == true
      assert candidate["bridge"] == ["cnk:1000001", "cnk:1000002"]
      assert candidate["members"] == %{"SK_1" => ["cnk:1000001"], "SK_2" => ["cnk:1000002"]}

      # the contradiction, per (key, field) dimension, with every source's candidate
      assert [conflict] = body["conflicts"]
      assert conflict["key"] == "SK_1"
      assert conflict["field"] == "name"

      assert Enum.sort_by(conflict["candidates"], & &1["source"]) == [
               %{"source" => "m", "value" => "Sunscreen"},
               %{"source" => "other", "value" => "Sun Screen"}
             ]

      # the code collision: one variant, two products claimed
      assert [collision] = body["code_collisions"]
      assert collision["key"] == "SK_1"

      assert Enum.sort_by(collision["products"], & &1["source"]) == [
               %{"source" => "m", "product" => 100},
               %{"source" => "other", "product" => 200}
             ]

      # the undecidables a steward would have to work
      assert Enum.sort_by(body["steward_queue"], & &1["type"]) == [
               %{"type" => "attribute", "subject" => "attr:SK_1/name"},
               %{"type" => "collision", "subject" => "collision:SK_1"},
               %{"type" => "merge", "subject" => "merge:SK_1+SK_2"}
             ]

      # the funnel line is rendered and quantified
      assert body["summary"] =~ "1 merge candidate"
      assert body["summary"] =~ "1 conflict"
    end

    test "a key bridged SOLELY by a barcode-grade code is a SUSPECT merge candidate" do
      post!("/v1/claims", %{
        claims: [
          %{
            kind: "identity",
            source: "m",
            ref: "A",
            codes: ["cnk:1000001", "gtin:05012345678900"]
          },
          %{kind: "identity", source: "m", ref: "B", codes: ["cnk:1000002"]}
        ]
      })

      dry =
        decoded(
          post!("/v1/dry-run", %{
            claims: [
              %{
                kind: "identity",
                source: "other",
                ref: "K",
                codes: ["gtin:05012345678900", "cnk:1000002"]
              }
            ]
          })
        )

      assert [%{"suspect" => true, "keys" => ["SK_1", "SK_2"]}] = dry["merge_candidates"]
      assert dry["counts"]["suspect_merge_candidates"] == 1
    end
  end

  describe "POST /v1/dry-run — auth" do
    test "requires the PRODUCT token: missing or steward tokens are 401, nothing runs" do
      conn =
        conn(:post, "/v1/dry-run", JSON.encode!(@probe))
        |> put_req_header("content-type", "application/json")
        |> then(&Api.Router.call(&1, Api.Router.init([])))

      assert conn.status == 401

      assert post!("/v1/dry-run", @probe, "test-steward-token").status == 401
      assert Api.Store.log() == []
    end
  end
end
