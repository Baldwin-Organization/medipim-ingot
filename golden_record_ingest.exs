# golden_record_ingest.exs — the legacy-medipim ingest PoC walkthrough (bead gr-bxf).
#
#   Run:  mix run golden_record_ingest.exs
#
# A complete, end-to-end tour of the ingest pipeline (gr-cdy epic) over the COMPILED lib/ modules
# (HistoryEnvelope ▸ Rederivation ▸ GoldenRecords / LegacyXref / MigrationDiff). It:
#
#   1. loads the REAL fixture (medipim entity 422156) and projects its golden record;
#   2. builds the legacy -> surrogate-key cross-reference for it;
#   3. renders the migration diff — for 422156 the expected outcome is a quiet, stable :confirmed;
#   4. then walks the three synthetic scenarios — MERGE, SPLIT, COLLISION — so the demo covers every
#      classification a migrator acts on: confirmed / merged / split / collision.
#
# Stdlib only, no Hex deps. Presentation only — it changes nothing about identity or the engine.

alias GoldenRecord.{Events, PublicId}

defmodule Demo do
  @fixture "test/ingest/fixtures/medipim_be_422156.json"

  def run do
    real_422156()
    merge_scenario()
    split_scenario()
    collision_scenario()
    title("DONE — confirmed / merged / split / collision all surfaced")
  end

  # ════════════════════════════════════════════════════════════════════════════════════════
  # 1. The REAL fixture: medipim entity 422156. Three legacy listings converge on ONE surrogate
  #    key; the entity stays put — the expected, undramatic :stable / :confirmed outcome.
  defp real_422156 do
    title("1. REAL FIXTURE — medipim entity 422156 (expected: stable / confirmed)")

    env = HistoryEnvelope.load!(@fixture)

    %{records: records} = GoldenRecords.from_envelopes([env], 1)
    print_records(records)

    xref = LegacyXref.from_envelopes([env], 1)
    print_legacy_to_key(xref)

    report = MigrationDiff.from_envelopes([env], 1)
    IO.puts("")
    IO.puts(MigrationDiff.to_summary(report))

    f = finding_for(report, 422_156)

    IO.puts(
      "\n  -> entity 422156 is category \"#{f.category}\", relation \"#{f.relation}\" " <>
        "(the expected stable migration outcome)"
    )
  end

  # ════════════════════════════════════════════════════════════════════════════════════════
  # 2. MERGE — two legacy entities sharing a national CNK fuse onto ONE surrogate key. A national
  #    code is a trusted bridge, so the merge is high-confidence and does NOT need review.
  defp merge_scenario do
    title("2. MERGE — entities 1 and 2 share cnk:100 (expected: merged, trusted)")

    envs = [
      envelope(1, [id("A", "set", "cnk", "100", 10)]),
      envelope(2, [id("B", "set", "cnk", "100", 10)])
    ]

    xref = LegacyXref.from_envelopes(envs, 1)
    print_legacy_to_key(xref)

    report = MigrationDiff.from_envelopes(envs, 1)
    f = finding_for(report, 1)

    IO.puts(
      "\n  -> entity 1 is category \"#{f.category}\", confidence \"#{f.confidence}\", " <>
        "needs_review #{f.needs_review} (a national CNK bridge is trusted)"
    )
  end

  # ════════════════════════════════════════════════════════════════════════════════════════
  # 3. SPLIT — one legacy entity (700) carries two DISJOINT bridging codes (a CNK and a GTIN), so it
  #    fragments into two clusters -> two surrogate keys. Primary is the CNK-bearing (spine) key.
  defp split_scenario do
    title("3. SPLIT — entity 700 carries disjoint cnk:555 + gtin (expected: split)")

    envs = [
      envelope(700, [
        id("A", "set", "cnk", "555", 10),
        id("B", "set", "gtin", "05012345678900", 10)
      ])
    ]

    xref = LegacyXref.from_envelopes(envs, 1)
    print_legacy_to_key(xref)

    report = MigrationDiff.from_envelopes(envs, 1)
    f = finding_for(report, 700)

    IO.puts(
      "\n  -> entity 700 is category \"#{f.category}\" across keys [#{Enum.join(f.keys, ", ")}], " <>
        "primary #{f.primary} (the CNK spine key)"
    )
  end

  # ════════════════════════════════════════════════════════════════════════════════════════
  # 4. COLLISION — a CNK on TWO distinct keys, an invariant VIOLATION that always needs review.
  #
  #    WHY this is hand-assembled (NOT built from envelopes): a true CNK collision CANNOT arise from
  #    envelopes, because two listings that share a CNK MERGE into one cluster — they never collide.
  #    So we hand-build an identity log placing the same CNK on two distinct keys and render it
  #    through the diff (the proven pattern from migration_diff_test.exs "CNK collision").
  defp collision_scenario do
    title("4. COLLISION — cnk:777 on two keys (expected: collision, needs_review)")

    log = [
      %Events.IdentityMinted{key: "SK_1", codes: MapSet.new([{:cnk, "777"}]), recorded_at: 10},
      %Events.IdentityMinted{key: "SK_2", codes: MapSet.new([{:cnk, "777"}]), recorded_at: 10}
    ]

    collisions = PublicId.collisions(:cnk, log)
    report = MigrationDiff.render(%{}, collisions)
    IO.puts(MigrationDiff.to_summary(report))

    f = Enum.find(report.findings, &(&1.category == "collision"))

    IO.puts(
      "\n  -> #{f.code} is category \"#{f.category}\", confidence \"#{f.confidence}\", " <>
        "needs_review #{f.needs_review} (a CNK invariant violation, always surfaced)"
    )
  end

  # ── synthetic-envelope helpers (same terse shape as the ingest tests) ──────────
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

  # ── presentation ──────────────────────────────────────────────────────────────
  defp print_records(records) do
    IO.puts("  golden records:")

    Enum.each(records, fn %{product: product, variants: variants} ->
      IO.puts("    product #{inspect(product)}")

      Enum.each(variants, fn v ->
        IO.puts("      variant #{v.key}  codes: #{Enum.map_join(v.codes, ", ", &lc/1)}")
        IO.puts("        CNK: #{cnk_line(v.cnk)}")
      end)
    end)
  end

  defp print_legacy_to_key(%{legacy_to_key: legacy_to_key}) do
    IO.puts("  legacy -> surrogate-key map:")

    legacy_to_key
    |> Enum.sort_by(fn {entity, _} -> entity end)
    |> Enum.each(fn {entity, %{primary: primary, all: all, relation: relation}} ->
      IO.puts(
        "    legacy #{entity} -> #{primary}  (all: [#{Enum.join(all, ", ")}], " <>
          "relation: #{inspect(relation)})"
      )
    end)
  end

  defp cnk_line(nil), do: "—"

  defp cnk_line(%{canonical: canonical, aliases: aliases}) do
    case aliases do
      [] -> "canonical #{lc(canonical)}"
      _ -> "canonical #{lc(canonical)}, aliases #{Enum.map_join(aliases, ", ", &lc/1)}"
    end
  end

  defp lc({scheme, value}), do: "#{scheme}:#{value}"

  defp title(t), do: IO.puts("\n" <> String.duplicate("─", 100) <> "\n  " <> t <> "\n")
end

Demo.run()
