# The medipim migration end-to-end over HTTP (bead gr-w4l): the real fixtures (entities 422156 BE
# and 347025 FR) go through the product loop the design names — dry-run → fix the mapping →
# dry-run → cutover → read API (resolve / lookup / changes) — and the cutover CONVERGES:
# an identical second run appends nothing and churns no keys; a modified re-run supersedes only
# its own slots. The "customer mapping script" lives in this test (design §3: mapping is code,
# in the customer's language); the medipim adapter's canonical_claims/1 plays the export half.
# async: false — shared tables.

defmodule Api.E2eMigrationTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @fixtures Path.expand("../../test/ingest/fixtures", __DIR__)
  @shadow_oracle Path.expand("fixtures/medipim_shadow_window.expected.json", __DIR__)

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

  # ── the customer's mapping script ───────────────────────────────────────────
  # First cut: medipim envelopes → live-wire claims, naively. It still ships legacy warts the
  # contract rejects (nil sources, nil and list-valued attributes) — exactly what the first
  # dry-run is for.
  defp naive_mapping do
    ["medipim_be_422156.json", "medipim_fr_347025.json"]
    |> Enum.map(&HistoryEnvelope.load!(Path.join(@fixtures, &1)))
    |> ClaimMapping.canonical_claims()
    # member_of is not on the live wire yet (docs/CLAIMS_CONTRACT.md, open question 1)
    |> Enum.reject(&(&1["kind"] == "member_of"))
    # the live wire owns recorded_at (server clock); both interval ends become ISO dates
    |> Enum.map(fn m ->
      m
      |> Map.delete("recorded_at")
      |> Map.update!("valid_from", &iso/1)
      |> then(fn m -> if m["valid_to"], do: Map.update!(m, "valid_to", &iso/1), else: m end)
    end)
  end

  # The fix after the first dry-run report: drop unattributed claims and null values, scalarize
  # list values — the iteration loop the funnel is built around.
  defp fixed_mapping do
    naive_mapping()
    |> Enum.reject(&is_nil(&1["source"]))
    |> Enum.reject(&(&1["kind"] == "attribute" and is_nil(&1["value"])))
    |> Enum.map(fn
      %{"value" => v} = m when is_list(v) -> Map.put(m, "value", Enum.join(v, ","))
      m -> m
    end)
  end

  defp iso(unix), do: unix |> DateTime.from_unix!() |> DateTime.to_date() |> Date.to_iso8601()

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

  # The PHP oracle and API allocate different product/media surrogate keys. Normalize the HTTP
  # document to their stable semantic intersection: status, canonical codes, full attribute
  # decisions, and the media source/URI multiset. API clocks, route legacy_id, merged_from, media
  # role (not exposed here), and all surrogate keys are deliberately excluded. The generated
  # fixture carries the same normalization description.
  defp shadow_view(legacy_id) do
    body = request(:get, "/v1/products/#{legacy_id}") |> decoded()

    attributes =
      body["attributes"]
      |> Enum.map(fn attribute ->
        candidates =
          attribute["candidates"]
          |> Enum.map(&Map.take(&1, ["source", "value"]))
          |> Enum.sort_by(&{&1["source"] || "", JSON.encode!(&1["value"])})

        attribute
        |> Map.take(["field", "value", "winner", "status"])
        |> Map.put("candidates", candidates)
      end)
      |> Enum.sort_by(& &1["field"])

    media =
      body["media"]
      |> Enum.map(&Map.take(&1, ["source", "uri"]))
      |> Enum.sort_by(&{&1["source"] || "", JSON.encode!(&1["uri"])})

    %{
      "status" => body["status"],
      "codes" => Enum.sort(body["codes"]),
      "attributes" => attributes,
      "media_count" => length(media),
      "media" => media
    }
  end

  test "dry-run catches the naive mapping; the fixed mapping cuts over; the read API serves both entities" do
    # ── iteration 1: the naive mapping is rejected, nothing committed ─────────
    naive = decoded(request(:post, "/v1/dry-run", %{claims: naive_mapping()}))
    assert naive["would_commit"] == false
    assert naive["counts"]["validation_errors"] > 0

    # a cutover of the same broken batch is a hard 422 — a cutover commits whole or not at all
    assert request(:post, "/v1/cutover", %{claims: naive_mapping()}).status == 422
    assert Api.Store.log() == []

    # ── iteration 2: the fixed mapping — the dry-run predicts the migration ───
    batch = fixed_mapping()
    dry = decoded(request(:post, "/v1/dry-run", %{claims: batch}))
    assert dry["would_commit"] == true
    assert dry["counts"]["mints"] == 2
    assert dry["counts"]["merge_candidates"] == 0
    assert dry["counts"]["conflicts"] == 6
    assert dry["counts"]["steward_queue"] == 6

    # ── cutover: committed, and the report mirrors the dry-run's verdicts ─────
    cut = request(:post, "/v1/cutover", %{claims: batch})
    assert cut.status == 200
    report = decoded(cut)

    assert report["cutover"] == true
    assert report["committed"] == true
    assert report["mints"] == dry["mints"]
    assert report["merge_candidates"] == dry["merge_candidates"]
    assert report["conflicts"] == dry["conflicts"]
    assert report["steward_queue"] == dry["steward_queue"]

    # Migration semantics: the batch is the source's current truth, so slot history compacts.
    # The totals grew when identity and grouping became per-period (gr-blb) — the same facts,
    # now carrying the interval each one applied for, plus one claim per code a source held —
    # and again with gr-4iu, when events outside a source's held window gained an anchor.
    assert report["counts"]["compacted"] == 71
    assert report["counts"]["accepted"] == 233
    assert report["counts"]["skipped"] == 0

    # lineage: both legacy entities keep their ids on the minted keys
    assert report["lineage"] |> Enum.map(& &1["legacy_id"]) |> Enum.sort() == [347_025, 422_156]
    key_of = Map.new(report["lineage"], &{&1["legacy_id"], &1["key"]})

    # ── the read API: resolve / lookup / changes ───────────────────────────────
    for legacy_id <- [422_156, 347_025] do
      body = decoded(request(:get, "/v1/products/#{legacy_id}"))
      assert body["key"] == key_of[legacy_id]
      assert body["status"] == "active"
      assert body["codes"] != []
    end

    # lookup by code lands on the same key the lineage minted
    product = decoded(request(:get, "/v1/products/422156"))
    cnk = Enum.find(product["codes"], &String.starts_with?(&1, "cnk:"))
    assert cnk
    by_code = decoded(request(:get, "/v1/products/by-code/#{String.replace(cnk, ":", "/")}"))
    assert Enum.any?(by_code["products"], &(&1["key"] == key_of[422_156]))

    # the change feed replays the whole migration in order
    feed = decoded(request(:get, "/v1/changes?since=0&limit=1000"))
    types = feed["events"] |> Enum.map(& &1["type"]) |> Enum.uniq()
    assert "claim" in types
    assert "minted" in types
    assert "legacy_id_assigned" in types
    offsets = Enum.map(feed["events"], & &1["offset"])
    assert offsets == Enum.sort(offsets)

    # ── the steward queue is seeded with exactly the undecidables predicted ───
    queue = decoded(request(:get, "/steward/v1/queue", nil, "test-steward-token"))
    assert queue["open"] == 6

    predicted =
      dry["steward_queue"]
      |> Enum.filter(&(&1["type"] == "attribute"))
      |> Enum.map(& &1["subject"])
      |> Enum.sort()

    seeded =
      queue["attributes"]
      |> Enum.map(&"attr:#{&1["key"]}/#{&1["field"]}")
      |> Enum.sort()

    assert seeded == predicted
  end

  test "an identical second cutover converges: zero events, zero key churn, empty lineage" do
    batch = fixed_mapping()
    first = decoded(request(:post, "/v1/cutover", %{claims: batch}))
    key = decoded(request(:get, "/v1/products/422156"))["key"]

    before_tables = tables()
    second = decoded(request(:post, "/v1/cutover", %{claims: batch}))

    assert second["counts"]["accepted"] == 0
    assert second["counts"]["skipped"] == 233
    assert second["counts"]["mints"] == 0
    assert second["lineage"] == []

    # no duplicate events, no snapshot drift — the log did not move at all
    assert tables() == before_tables

    # no surrogate-key churn, and the standing steward queue is reported, not re-seeded
    assert decoded(request(:get, "/v1/products/422156"))["key"] == key
    assert second["steward_queue"] == first["steward_queue"]
  end

  test "a modified re-run supersedes cleanly: only the changed slots land, keys stay stable" do
    batch = fixed_mapping()
    request(:post, "/v1/cutover", %{claims: batch})

    key = decoded(request(:get, "/v1/products/422156"))["key"]
    before_count = decoded(request(:get, "/v1/changes?since=0&limit=1000"))["count"]

    # the customer fixes the French name in their mapping — every source now agrees
    corrected = "Crème solaire — nom corrigé"

    modified =
      Enum.map(batch, fn
        %{"kind" => "attribute", "field" => "name:fr"} = m -> Map.put(m, "value", corrected)
        m -> m
      end)

    report = decoded(request(:post, "/v1/cutover", %{claims: modified}))

    # The name:fr slots supersede and nothing else moves. Six rather than four now: the source
    # held three codes in its last period, so one changed fact is one claim per code.
    assert report["counts"]["accepted"] == 6
    assert report["counts"]["skipped"] == 227
    assert report["counts"]["mints"] == 0
    assert report["lineage"] == []

    after_feed = decoded(request(:get, "/v1/changes?since=0&limit=1000"))
    assert after_feed["count"] == before_count + 6

    new_events = Enum.drop(after_feed["events"], before_count)
    assert Enum.all?(new_events, &(&1["type"] == "claim"))

    # same key, new value — and the name:fr conflicts are gone from the steward queue
    product = decoded(request(:get, "/v1/products/422156"))
    assert product["key"] == key

    name_fr = Enum.find(product["attributes"], &(&1["field"] == "name:fr"))
    assert name_fr["value"] == corrected

    queue = decoded(request(:get, "/steward/v1/queue", nil, "test-steward-token"))
    assert queue["open"] == 4
    refute Enum.any?(queue["attributes"], &(&1["field"] == "name:fr"))
  end

  test "shadow parity stays exact through a source refresh and a late-arriving correction" do
    oracle = @shadow_oracle |> File.read!() |> JSON.decode!() |> Map.fetch!("phases")
    batch = fixed_mapping()
    assert decoded(request(:post, "/v1/cutover", %{claims: batch}))["committed"]
    assert shadow_view(422_156) == oracle["baseline"]

    refreshed =
      Enum.map(batch, fn
        %{"kind" => "attribute", "field" => "name:fr"} = claim ->
          Map.put(claim, "value", "Nom rafraîchi")

        claim ->
          claim
      end)

    assert decoded(request(:post, "/v1/cutover", %{claims: refreshed}))["committed"]
    assert shadow_view(422_156) == oracle["source_refresh"]

    late =
      Enum.find(refreshed, fn claim ->
        claim["kind"] == "attribute" and claim["field"] == "name:fr"
      end)
      |> Map.merge(%{"value" => "Correction arrivée en retard", "valid_from" => "2024-01-01"})

    assert request(:post, "/v1/claims", %{claims: [late]}).status == 200
    assert shadow_view(422_156) == oracle["late_arriving_correction"]
  end

  test "cutover requires the product token" do
    conn =
      conn(:post, "/v1/cutover", JSON.encode!(%{claims: fixed_mapping()}))
      |> put_req_header("content-type", "application/json")
      |> then(&Api.Router.call(&1, Api.Router.init([])))

    assert conn.status == 401

    assert request(:post, "/v1/cutover", %{claims: fixed_mapping()}, "test-steward-token").status ==
             401

    assert Api.Store.log() == []
  end
end
