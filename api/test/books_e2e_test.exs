# The genericity gate end-to-end (bead gr-vgb): a SECOND, non-pharma vertical — BOOK records,
# ISBN-10/ISBN-13 from two overlapping sources — goes through the exact product loop the medipim
# migration uses (dry-run → cutover → reads → steward queue) with ZERO engine changes. Everything
# book-specific is config + adapter: CodeRegistry's isbn data rows, the Isbn module, the
# BooksAdapter mapping, and fixtures. `git diff` on lib/golden_record_core.ex against the base
# branch is the gate; this suite is the behavioral proof. async: false — shared tables.

defmodule Api.BooksE2eTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @fixtures Path.expand("../../test/ingest/fixtures/books", __DIR__)

  setup do
    {:ok, :ok} = Api.Store.reset!()
    :ok
  end

  defp request(method, path, body \\ nil, token \\ "test-product-token") do
    conn(method, path, body && JSON.encode!(body))
    |> then(&if(body, do: put_req_header(&1, "content-type", "application/json"), else: &1))
    |> put_req_header("authorization", "Bearer #{token}")
    |> then(&Api.Router.call(&1, Api.Router.init([])))
  end

  defp decoded(conn), do: JSON.decode!(conn.resp_body)

  # ── the customer's mapping script: two book dumps → live-wire claims ──────────
  defp batch do
    BooksAdapter.claims(
      Path.join(@fixtures, "librex_catalog.json"),
      Path.join(@fixtures, "bookwire_feed.json")
    )
  end

  defp update, do: BooksAdapter.bookwire_claims(Path.join(@fixtures, "bookwire_feed_update.json"))

  defp tables do
    %{rows: events} =
      Postgrex.query!(
        Api.DB,
        ~s(SELECT "offset", type, payload::text FROM events ORDER BY "offset"),
        []
      )

    %{rows: projections} =
      Postgrex.query!(
        Api.DB,
        """
        SELECT 'checkpoint', name, payload::text FROM projection_checkpoints
        UNION ALL
        SELECT 'golden', key, payload::text FROM golden_records
        ORDER BY 1, 2
        """,
        []
      )

    {events, projections}
  end

  test "books migrate through dry-run → cutover → reads; the 10/13 pair is ONE golden record" do
    # ── dry-run: the funnel artifact predicts the whole migration ──────────────
    dry = decoded(request(:post, "/v1/dry-run", %{claims: batch()}))
    assert dry["would_commit"] == true
    assert dry["counts"]["validation_errors"] == 0
    assert dry["counts"]["mints"] == 4
    assert dry["counts"]["conflicts"] == 1
    assert dry["counts"]["merge_candidates"] == 0
    assert dry["counts"]["code_collisions"] == 1
    assert dry["counts"]["steward_queue"] == 2
    assert Api.Store.log() == []

    # ── cutover: committed, mirroring the dry-run's verdicts ───────────────────
    cut = request(:post, "/v1/cutover", %{claims: batch()})
    assert cut.status == 200
    report = decoded(cut)

    assert report["committed"] == true
    assert report["mints"] == dry["mints"]
    assert report["conflicts"] == dry["conflicts"]
    assert report["code_collisions"] == dry["code_collisions"]
    assert report["steward_queue"] == dry["steward_queue"]
    assert report["counts"]["accepted"] == 36
    assert report["counts"]["skipped"] == 0
    assert report["counts"]["compacted"] == 0

    # lineage: librex ids carry over; the bookwire-only 979 title gets a fresh id above them
    assert report["lineage"] |> Enum.map(& &1["legacy_id"]) |> Enum.sort() == [
             1001,
             1002,
             1004,
             1005
           ]

    # ── equivalence: librex "1-86197-271-7" + bookwire "978-1-86197-271-2" → ONE record
    tide = decoded(request(:get, "/v1/products/1001"))
    assert tide["status"] == "active"
    assert tide["codes"] == ["isbn13:9781861972712"]
    assert Enum.find(tide["attributes"], &(&1["field"] == "title"))["value"] == "The Tide Atlas"

    by_code = decoded(request(:get, "/v1/products/by-code/isbn13/9781861972712"))
    assert [product] = by_code["products"]
    assert product["key"] == tide["key"]

    # ── contradiction surfaced PER DIMENSION: pages disagrees, title does not ──
    assert [conflict] = report["conflicts"]
    assert conflict["key"] == tide["key"]
    assert conflict["field"] == "pages"

    assert Enum.sort_by(conflict["candidates"], & &1["source"]) == [
             %{"source" => "bookwire", "value" => 256},
             %{"source" => "librex", "value" => 240}
           ]

    # ── code collision: one sku spans both librex editions — flagged, not picked ─
    assert [collision] = report["code_collisions"]
    assert collision["products"] |> Enum.map(& &1["product"]) |> Enum.sort() == [1002, 1003]

    lichens = decoded(request(:get, "/v1/products/1002"))
    assert lichens["codes"] == ["isbn13:9780198526636", "isbn13:9780198526643"]
    assert collision["key"] == lichens["key"]

    # the steward queue holds the attribute tie (the collision is in the migration report)
    queue = decoded(request(:get, "/steward/v1/queue", nil, "test-steward-token"))
    assert [attr] = queue["attributes"]
    assert {attr["key"], attr["field"]} == {tide["key"], "pages"}
  end

  test "an identical second cutover converges: zero events, zero key churn, empty lineage" do
    first = decoded(request(:post, "/v1/cutover", %{claims: batch()}))
    key = decoded(request(:get, "/v1/products/1001"))["key"]

    before_tables = tables()
    second = decoded(request(:post, "/v1/cutover", %{claims: batch()}))

    assert second["counts"]["accepted"] == 0
    assert second["counts"]["skipped"] == 36
    assert second["counts"]["mints"] == 0
    assert second["lineage"] == []
    assert second["steward_queue"] == first["steward_queue"]

    assert tables() == before_tables
    assert decoded(request(:get, "/v1/products/1001"))["key"] == key
  end

  test "new evidence bridging two ESTABLISHED books is queued for a steward, never auto-merged" do
    request(:post, "/v1/cutover", %{claims: batch()})

    hardcover = decoded(request(:get, "/v1/products/1004"))
    [collected] = decoded(request(:get, "/v1/products/by-code/isbn13/9791090636071"))["products"]
    assert hardcover["key"] != collected["key"]

    # the dry-run predicts the merge candidate — trusted (national-grade ISBN bridge), still gated
    dry = decoded(request(:post, "/v1/dry-run", %{claims: update()}))
    assert [candidate] = dry["merge_candidates"]
    assert Enum.sort([hardcover["key"], collected["key"]]) == candidate["keys"]
    assert candidate["new"] == true
    assert candidate["suspect"] == false
    assert "isbn13:9780571199983" in candidate["bridge"]

    # submitting it flags a merge proposal; identity does NOT fuse
    resp = decoded(request(:post, "/v1/claims", %{claims: update()}))
    assert resp["flagged"] == [%{"type" => "merge_proposal", "keys" => candidate["keys"]}]

    assert decoded(request(:get, "/v1/products/1004"))["key"] == hardcover["key"]

    [still_collected] =
      decoded(request(:get, "/v1/products/by-code/isbn13/9791090636071"))["products"]

    assert still_collected["key"] == collected["key"]
    assert still_collected["status"] == "active"

    # the steward queue holds the proposal open
    queue = decoded(request(:get, "/steward/v1/queue", nil, "test-steward-token"))
    assert [merge] = queue["merges"]
    assert merge["keys"] == candidate["keys"]

    # re-submitting the same evidence converges — nothing re-appends, the proposal stays open
    again = decoded(request(:post, "/v1/claims", %{claims: update()}))
    assert again["accepted"] == 0
    assert again["skipped"] == 4

    queue2 = decoded(request(:get, "/steward/v1/queue", nil, "test-steward-token"))
    assert Enum.map(queue2["merges"], & &1["keys"]) == [candidate["keys"]]
  end
end
