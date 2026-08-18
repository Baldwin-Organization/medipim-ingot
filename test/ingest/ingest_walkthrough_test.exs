# test/ingest/ingest_walkthrough_test.exs — the end-to-end PoC walkthrough test (bead gr-bxf).
#
#   Run:  mix test
#
# The INTEGRATION test for the legacy-medipim ingest (gr-cdy epic): it drives the SAME full pipeline
# the golden_record_ingest.exs demo does and asserts each migration classification surfaces. Distinct
# from the per-module unit tests (legacy_xref_test / migration_diff_test / golden_records_test) — it
# does not duplicate them; it proves the projections compose end-to-end, from the real 422156 fixture
# (golden record + xref + a stable/confirmed diff) through the three synthetic scenarios (merge,
# split, collision). Mirrors the terse synthetic-envelope helpers from migration_diff_test.exs.

alias GoldenRecord.{Events, PublicId}

defmodule IngestWalkthroughTest do
  use ExUnit.Case, async: true

  @fixture Path.join(__DIR__, "fixtures/medipim_be_422156.json")

  # ── helpers (same shape as migration_diff_test.exs) ─────────────────────────
  defp envelope(entity, events) do
    {:ok, env} =
      HistoryEnvelope.from_map(%{
        "schema_version" => "1",
        "legacy_entity" => entity,
        "events" => events
      })

    env
  end

  defp id(source, op, scheme, code, at),
    do: %{
      "recorded_at" => at,
      "source" => source,
      "op" => op,
      "kind" => "identity",
      "scheme" => scheme,
      "code" => code
    }

  defp finding_for(report, entity),
    do: Enum.find(report.findings, &(Map.get(&1, :legacy_entity) == entity))

  # ── 1. the REAL 422156 fixture: golden record + xref + a stable/confirmed diff ────
  describe "real entity 422156 end-to-end" do
    setup do
      env = HistoryEnvelope.load!(@fixture)

      %{
        gr: GoldenRecords.from_envelopes([env], 1),
        xref: LegacyXref.from_envelopes([env], 1),
        report: MigrationDiff.from_envelopes([env], 1)
      }
    end

    test "the golden record is one product 422156 with a CNK-bearing variant", %{gr: gr} do
      assert [%{product: 422_156, variants: [variant]}] = gr.records
      assert {:cnk, "3612173"} in variant.codes
    end

    test "the migration diff classifies 422156 as confirmed / stable", %{report: report} do
      f = finding_for(report, 422_156)
      assert f.category == "confirmed"
      assert f.relation == "stable"
    end

    test "the xref lands 422156 on its sole, stable key", %{xref: xref} do
      assert xref.legacy_to_key[422_156] == %{primary: "SK_1", all: ["SK_1"], relation: :stable}
    end
  end

  # ── 2. MERGE: two entities sharing a national CNK -> merged, trusted ──────────────
  describe "merge scenario (shared CNK)" do
    setup do
      envs = [
        envelope(1, [id("A", "set", "cnk", "100", 10)]),
        envelope(2, [id("B", "set", "cnk", "100", 10)])
      ]

      %{report: MigrationDiff.from_envelopes(envs, 1)}
    end

    test "each entity is a trusted, high-confidence merge that needs no review", %{report: report} do
      for entity <- [1, 2] do
        f = finding_for(report, entity)
        assert f.category == "merged"
        assert f.confidence == "high"
        assert f.needs_review == false
      end
    end
  end

  # ── 3. SPLIT: one entity with disjoint codes fragments across two keys ────────────
  describe "split scenario (disjoint bridging codes)" do
    setup do
      envs = [
        envelope(700, [
          id("A", "set", "cnk", "555", 10),
          id("B", "set", "gtin", "05012345678900", 10)
        ])
      ]

      %{report: MigrationDiff.from_envelopes(envs, 1)}
    end

    test "entity 700 is a split across two keys", %{report: report} do
      f = finding_for(report, 700)
      assert f.category == "split"
      assert length(f.keys) == 2
    end

    test "the report counts exactly one split", %{report: report} do
      assert report.counts.split == 1
    end
  end

  # ── 4. COLLISION: a CNK on two keys -> collision, needs_review ────────────────────
  # Hand-assembled, NOT from envelopes: two listings sharing a CNK MERGE into one cluster (they
  # never collide), so a real collision can only be surfaced by placing the same CNK on two distinct
  # keys directly — the proven pattern from migration_diff_test.exs.
  describe "collision scenario (hand-assembled identity log)" do
    setup do
      log = [
        %Events.IdentityMinted{key: "SK_1", codes: MapSet.new([{:cnk, "777"}]), recorded_at: 10},
        %Events.IdentityMinted{key: "SK_2", codes: MapSet.new([{:cnk, "777"}]), recorded_at: 10}
      ]

      %{report: MigrationDiff.render(%{}, PublicId.collisions(:cnk, log))}
    end

    test "the CNK-on-two-keys collision is a needs_review finding naming the code", %{report: report} do
      f = Enum.find(report.findings, &(&1.category == "collision"))
      assert f.category == "collision"
      assert f.needs_review == true
      assert f.code == "cnk:777"
    end

    test "the report counts exactly one collision", %{report: report} do
      assert report.counts.collision == 1
    end
  end
end
