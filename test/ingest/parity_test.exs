# test/ingest/parity_test.exs — the whole-product parity harness (gr-yfh).
#
#   Run:  mix test
#
# Two halves, deliberately:
#
#   1. THE COHORT, over the real fixtures — the generalized 422156 byte-test. The committed
#      `*.snapshot.json` baselines must stay reproducible from the fold, and the discovered cohort
#      must diff clean apart from the survivorship ties (gr-7yw), which are the honest residue of
#      the permissive default priority.
#   2. THE CLASSIFIER, over hand-made pairs plus perturbations of the real baseline — every
#      divergence class, because a harness that cannot tell `applier_only` (a DROPPED field) from
#      `unresolved` (a tie) is worse than no harness: it makes gr-be3 unactionable.
#
# The baselines are engine-produced, so the cohort report carries `self_comparison` — asserted here
# too, since a report that hid that caveat would read as parity evidence it is not.

defmodule ParityTest do
  use ExUnit.Case, async: true

  @fixtures Path.join(__DIR__, "fixtures")
  @be Path.join(@fixtures, "medipim_be_422156.json")

  # A wire snapshot with every lane present — what `load_snapshot!/1` insists on.
  defp wire(fields) do
    Map.merge(
      %{
        "schema_version" => "1",
        "produced_by" => "applier",
        "source_system" => "medipim-be",
        "legacy_entity" => 1,
        "identity" => [],
        "attributes" => %{},
        "edges" => [],
        "media" => [],
        "descriptions" => []
      },
      fields
    )
  end

  defp engine(fields), do: %{"produced_by" => "engine", "keys" => ["SK_1"]} |> Map.merge(fields) |> wire()

  defp classification(report, field),
    do: Enum.find_value(report.divergences, &(&1.field == field && &1.classification))

  # ── 1. the cohort: the real fixtures ─────────────────────────────────────────

  describe "the engine snapshot of the real fixtures" do
    test "reproduces both committed baselines" do
      for stem <- ~w(medipim_be_422156 medipim_fr_347025) do
        envelope = HistoryEnvelope.load!(Path.join(@fixtures, stem <> ".json"))
        committed = @fixtures |> Path.join(stem <> ".snapshot.json") |> ParityHarness.load_snapshot!()

        assert JSON.decode!(JSON.encode!(ParityHarness.snapshot([envelope]))) == committed,
               "#{stem}.snapshot.json is stale — regenerate: " <>
                 "mix run test/ingest/fixtures/gen_parity_snapshots.exs"
      end
    end

    test "speaks the applier's vocabulary: legacy media/description ids, not surrogate keys" do
      snapshot = ParityHarness.snapshot([HistoryEnvelope.load!(@be)])

      assert "158717" in snapshot["media"]
      assert "401512" in snapshot["descriptions"]
      refute Enum.any?(snapshot["media"] ++ snapshot["descriptions"], &String.contains?(&1, "_"))

      assert snapshot["identity"] == ["cnk:3612173", "gtin:03282770114577", "gtin:03282770146004"]
      assert "organizations:1035" in snapshot["edges"]
    end

    test "separates the fields survivorship resolved from the ties it could not" do
      snapshot = ParityHarness.snapshot([HistoryEnvelope.load!(@be)])

      assert snapshot["attributes"]["status"] == "active"
      assert Map.keys(snapshot["unresolved"]) == ~w(name:fr name:nl publicPrice weight width)
      refute Map.has_key?(snapshot["attributes"], "name:nl")
      assert ["1034", "Aderma Primalba Wasgel 2in1 750ml"] in snapshot["unresolved"]["name:nl"]
    end
  end

  describe "the discovered cohort" do
    setup do: %{report: ParityHarness.from_dir(@fixtures)}

    test "pairs every snapshot with its envelope and folds both entities", %{report: report} do
      assert report.cohort.entities == 2
      assert Enum.map(report.cases, & &1.legacy_entity) == [422_156, 347_025]
      assert Enum.all?(report.cases, &(&1.keys == ["SK_1"]))
    end

    test "diverges ONLY on survivorship ties — no mapping gap in either direction", %{report: report} do
      assert report.counts.value_mismatch == 0
      assert report.counts.engine_only == 0
      assert report.counts.applier_only == 0
      assert report.counts.cardinality == 0

      # gr-gh0: parting attributes at the exact delisting instant now reach claims, so two
      # 347025 fields gained a competing candidate and moved from match to unresolved.
      # gr-4iu: nearest-codes anchoring recovers events outside the held window; one more
      # field reaches the engine fold and matches the applier snapshot.
      assert report.counts.unresolved == 13
      assert report.counts.match == 75
      assert Enum.all?(report.divergences, &(&1.classification == :unresolved))
    end

    test "flags itself as a self-comparison rather than parity evidence", %{report: report} do
      assert report.cohort.self_comparison == [422_156, 347_025]
      assert report |> ParityHarness.to_summary() |> String.contains?("SELF-COMPARISON")
    end

    test "is JSON-safe end to end", %{report: report} do
      decoded = report |> ParityHarness.to_json() |> JSON.decode!()

      assert decoded["cohort"]["entities"] == 2
      assert hd(decoded["divergences"])["classification"] == "unresolved"
    end
  end

  # ── 2. the classifier ────────────────────────────────────────────────────────

  describe "classification" do
    test "agreement on every lane is counted, never itemized" do
      both = %{
        "identity" => ["cnk:100"],
        "attributes" => %{"status" => "active", "weight" => 859},
        "edges" => ["brands:9"],
        "media" => ["158717"],
        "descriptions" => ["401512"]
      }

      report = ParityHarness.compare(engine(both), wire(both))

      assert report.clean
      assert report.counts.match == 6
      assert report.divergences == []
    end

    test "a field both sides hold with different values is a value_mismatch" do
      report =
        ParityHarness.compare(
          engine(%{"attributes" => %{"weight" => 859}}),
          wire(%{"attributes" => %{"weight" => 780}})
        )

      assert [%{lane: :attribute, field: "weight", engine: 859, applier: 780}] = report.divergences
      assert classification(report, "weight") == :value_mismatch
    end

    test "a field only the applier holds is applier_only — the dropped-mapping class" do
      report = ParityHarness.compare(engine(%{}), wire(%{"attributes" => %{"packagingUnit" => "ml"}}))

      assert classification(report, "packagingUnit") == :applier_only
      assert report.counts.applier_only == 1
    end

    test "a field only the engine claims is engine_only, null values included" do
      report = ParityHarness.compare(engine(%{"attributes" => %{"tradeInRefundValue" => nil}}), wire(%{}))

      assert classification(report, "tradeInRefundValue") == :engine_only
    end

    test "a survivorship tie is :unresolved with its candidates, not a value_mismatch" do
      report =
        ParityHarness.compare(
          engine(%{"unresolved" => %{"name:nl" => [["1034", "Aderma"], ["1035", "ADERMA"]]}}),
          wire(%{"attributes" => %{"name:nl" => "Aderma"}})
        )

      assert [divergence] = report.divergences
      assert divergence.classification == :unresolved
      assert divergence.engine == nil
      assert divergence.applier == "Aderma"
      assert divergence.candidates == [["1034", "Aderma"], ["1035", "ADERMA"]]
      assert report.counts.value_mismatch == 0
    end

    test "set lanes report one-sided members on both sides" do
      report =
        ParityHarness.compare(
          engine(%{"identity" => ["cnk:100"], "media" => []}),
          wire(%{"identity" => [], "media" => ["158717"]})
        )

      assert classification(report, "cnk:100") == :engine_only
      assert classification(report, "158717") == :applier_only
      assert Enum.map(report.divergences, & &1.lane) == [:identity, :media]
    end

    test "an entity that re-derived to more than one key is a cardinality divergence" do
      report = ParityHarness.compare(engine(%{"keys" => ["SK_1", "SK_2"]}), wire(%{}))

      assert [%{lane: :product, field: "variants", engine: 2, applier: 1}] = report.divergences
      assert classification(report, "variants") == :cardinality
    end

    test "divergences are ordered by lane then field, so reports are diffable" do
      report =
        ParityHarness.compare(
          engine(%{"keys" => [], "identity" => ["cnk:100"]}),
          wire(%{"attributes" => %{"zeta" => 1, "alpha" => 2}, "media" => ["1"]})
        )

      assert Enum.map(report.divergences, &{&1.lane, &1.field}) == [
               {:attribute, "alpha"},
               {:attribute, "zeta"},
               {:identity, "cnk:100"},
               {:media, "1"},
               {:product, "variants"}
             ]
    end
  end

  describe "a perturbed real cohort (what a genuine applier divergence looks like)" do
    setup do
      [be | _] = ParityHarness.cohort!(@fixtures)

      applier =
        be.applier
        |> Map.put("produced_by", "applier")
        |> Map.update!("identity", &(&1 -- ["cnk:3612173"]))
        |> Map.update!("media", &["999999" | &1])
        |> Map.update!("attributes", &%{&1 | "status" => "delisted"})
        |> Map.update!("attributes", &Map.put(&1, "packagingUnit", "ml"))

      %{report: ParityHarness.run([%{be | applier: applier}])}
    end

    test "classifies each planted divergence, in its lane", %{report: report} do
      assert classification(report, "cnk:3612173") == :engine_only
      assert classification(report, "999999") == :applier_only
      assert classification(report, "status") == :value_mismatch
      assert classification(report, "packagingUnit") == :applier_only
      assert report.counts.applier_only == 2
    end

    test "reports the entity as diverging and stops calling it a self-comparison", %{report: report} do
      assert report.cohort == %{entities: 1, clean: 0, diverging: 1, self_comparison: []}
      assert Enum.all?(report.divergences, &(&1.legacy_entity == 422_156))
    end

    test "the human summary itemizes them as the gap worklist", %{report: report} do
      summary = ParityHarness.to_summary(report)

      assert summary =~ "422156 attribute/status: value_mismatch"
      assert summary =~ "422156 identity/cnk:3612173: engine_only"
      refute summary =~ "SELF-COMPARISON"
    end
  end

  describe "loading an applier snapshot" do
    setup do
      path = Path.join(System.tmp_dir!(), "parity_#{System.unique_integer([:positive])}.snapshot.json")
      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "refuses a file missing a lane, rather than reading it as 'the applier has none'", %{path: path} do
      File.write!(path, JSON.encode!(Map.delete(wire(%{}), "media")))

      assert_raise ArgumentError, ~r/missing media/, fn -> ParityHarness.load_snapshot!(path) end
    end

    test "refuses an unsupported schema_version", %{path: path} do
      File.write!(path, JSON.encode!(wire(%{"schema_version" => "2"})))

      assert_raise ArgumentError, ~r/unsupported parity snapshot schema_version "2"/, fn ->
        ParityHarness.load_snapshot!(path)
      end
    end
  end
end
