# test/ingest/migration_diff_test.exs — ExUnit for the migration-diff VIEW (bead gr-swc).
#
#   Run:  mix test
#
# The diff is a pure RENDERING over LegacyXref's `legacy_to_key` relation + PublicId.collisions(:cnk).
# Most cases drive it end-to-end from synthetic envelopes (same terse helpers as
# legacy_xref_test.exs): a :stable convergence -> confirmed, a shared-CNK MERGE -> trusted/merged,
# a disjoint-listing SPLIT -> split. Two cases the engine can't naturally produce here are fed to
# the pure renderer directly: the SUSPECT (barcode-only) merge variant gr-ose emits — asserted via
# the PINNED `{:merged, [other], :suspect}` contract, no dependency on gr-ose's logic — and a CNK
# COLLISION, built from a hand-assembled identity log so PublicId.collisions(:cnk, log) returns a
# real invariant violation.

alias GoldenRecord.{Events, PublicId}

defmodule MigrationDiffTest do
  use ExUnit.Case, async: true

  # ── helpers (same shape as legacy_xref_test.exs) ────────────────────────────
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

  # ── :stable -> confirmed ─────────────────────────────────────────────────────
  describe "stable convergence" do
    setup do
      envs = [envelope(500, [id("A", "set", "cnk", "900", 10)])]
      %{report: MigrationDiff.from_envelopes(envs, 1)}
    end

    test "the lone 1:1 entity is a confirmed, high-confidence finding", %{report: report} do
      f = finding_for(report, 500)
      assert f.category == "confirmed"
      assert f.relation == "stable"
      assert f.confidence == "high"
      refute f.needs_review
    end

    test "counts it under confirmed and nothing needs review", %{report: report} do
      assert report.counts.confirmed == 1
      assert report.counts.needs_review == 0
      assert report.needs_review == []
    end
  end

  # ── national (CNK) merge -> merged, trusted ──────────────────────────────────
  describe "national (CNK) merge" do
    setup do
      envs = [
        envelope(1, [id("A", "set", "cnk", "100", 10)]),
        envelope(2, [id("B", "set", "cnk", "100", 10)])
      ]

      %{report: MigrationDiff.from_envelopes(envs, 1)}
    end

    test "each entity is a trusted merge (high confidence, NOT needs_review)", %{report: report} do
      f1 = finding_for(report, 1)
      assert f1.category == "merged"
      assert f1.confidence == "high"
      refute f1.needs_review
      assert f1.evidence == %{merged_with: [2]}

      f2 = finding_for(report, 2)
      assert f2.evidence == %{merged_with: [1]}
      refute f2.needs_review
    end

    test "a trusted CNK merge carries no barcode bridge and stays out of needs_review", %{report: report} do
      assert report.counts.merged == 2
      assert report.counts.needs_review == 0
      refute Map.has_key?(finding_for(report, 1).evidence, :bridge)
    end
  end

  # ── SUSPECT (barcode-only) merge -> merged + needs_review ─────────────────────
  # Fed to the pure renderer via the PINNED `{:merged, [other], :suspect}` contract (gr-ose owns
  # producing it; this bead only consumes the shape). No dependency on gr-ose's logic.
  describe "suspect (barcode-only) merge" do
    setup do
      legacy_to_key = %{
        10 => %{primary: "SK_1", all: ["SK_1"], relation: {:merged, [11], :suspect}},
        11 => %{primary: "SK_1", all: ["SK_1"], relation: {:merged, [10], :suspect}}
      }

      %{report: MigrationDiff.render(legacy_to_key, [])}
    end

    test "a suspect merge is needs_review with low confidence and a barcode bridge", %{report: report} do
      f = finding_for(report, 10)
      assert f.category == "merged"
      assert f.confidence == "low"
      assert f.needs_review
      assert f.evidence == %{merged_with: [11], bridge: "barcode"}
    end

    test "both suspect merges are counted under needs_review", %{report: report} do
      assert report.counts.merged == 2
      assert report.counts.needs_review == 2
      assert length(report.needs_review) == 2
    end

    test "to_summary/1 itemizes the suspect merge", %{report: report} do
      summary = MigrationDiff.to_summary(report)
      assert summary =~ "Needs review (2):"
      assert summary =~ "merged (suspect): legacy 10 -> SK_1 with [11]"
      assert summary =~ "barcode-only bridge"
    end
  end

  # ── :split -> split, listing both keys ───────────────────────────────────────
  describe "split" do
    setup do
      envs = [
        envelope(700, [
          id("A", "set", "cnk", "555", 10),
          id("B", "set", "gtin", "05012345678900", 10)
        ])
      ]

      %{report: MigrationDiff.from_envelopes(envs, 1)}
    end

    test "the fragmented entity is a split finding listing BOTH keys", %{report: report} do
      f = finding_for(report, 700)
      assert f.category == "split"
      assert f.relation == "split"
      assert length(f.keys) == 2
      assert f.evidence.fragments == f.keys
      assert f.primary in f.keys
      refute f.needs_review
    end

    test "a split is high-confidence and not flagged for review", %{report: report} do
      assert report.counts.split == 1
      assert report.counts.needs_review == 0
    end
  end

  # ── CNK collision -> collision + needs_review ────────────────────────────────
  # Hand-build an identity log placing the SAME CNK on TWO keys, so PublicId.collisions(:cnk, log)
  # returns a real invariant violation; render it through the diff alongside an empty xref.
  describe "CNK collision" do
    setup do
      log = [
        %Events.IdentityMinted{key: "SK_1", codes: MapSet.new([{:cnk, "777"}]), recorded_at: 10},
        %Events.IdentityMinted{key: "SK_2", codes: MapSet.new([{:cnk, "777"}]), recorded_at: 10}
      ]

      collisions = PublicId.collisions(:cnk, log)
      %{report: MigrationDiff.render(%{}, collisions), collisions: collisions}
    end

    test "the engine actually reports the collision (precondition)", %{collisions: collisions} do
      assert collisions == [%{code: {:cnk, "777"}, keys: ["SK_1", "SK_2"]}]
    end

    test "a CNK on >1 key is a needs_review collision finding naming both keys", %{report: report} do
      f = Enum.find(report.findings, &(&1.category == "collision"))
      assert f.code == "cnk:777"
      assert f.keys == ["SK_1", "SK_2"]
      assert f.confidence == "low"
      assert f.needs_review
      assert f.evidence.collided_keys == ["SK_1", "SK_2"]
    end

    test "the collision is counted and itemized in to_summary/1", %{report: report} do
      assert report.counts.collision == 1
      assert report.counts.needs_review == 1
      summary = MigrationDiff.to_summary(report)
      assert summary =~ "collision: cnk:777 owns keys [SK_1, SK_2]"
    end
  end

  # ── JSON round-trip ──────────────────────────────────────────────────────────
  describe "to_json/1" do
    test "the machine form decodes back via JSON.decode/1" do
      envs = [
        envelope(1, [id("A", "set", "cnk", "100", 10)]),
        envelope(2, [id("B", "set", "cnk", "100", 10)]),
        envelope(700, [
          id("A", "set", "cnk", "555", 10),
          id("B", "set", "gtin", "05012345678900", 10)
        ])
      ]

      report = MigrationDiff.from_envelopes(envs, 1)
      json = MigrationDiff.to_json(report)

      assert is_binary(json)
      assert {:ok, decoded} = JSON.decode(json)
      assert is_list(decoded["findings"])
      assert is_map(decoded["counts"])
      # atoms round-trip as strings through the built-in JSON encoder.
      assert Enum.any?(decoded["findings"], &(&1["category"] == "merged"))
    end

    test "a report carrying needs_review findings still round-trips" do
      legacy_to_key = %{
        10 => %{primary: "SK_1", all: ["SK_1"], relation: {:merged, [11], :suspect}}
      }

      report = MigrationDiff.render(legacy_to_key, [])
      assert {:ok, decoded} = JSON.decode(MigrationDiff.to_json(report))
      assert decoded["counts"]["needs_review"] == 1
    end
  end
end
