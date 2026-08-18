# temporal_ingest.exs — the temporal pass PoC walkthrough (bead gr-aqb, epic gr-nh0).
#
#   Run:  mix run temporal_ingest.exs
#
# A runnable tour of the temporal pass (lib/ingest/temporal.ex, T1 gr-a2j) over the COMPILED lib/
# modules. It folds the SAME claims the v1 ingest uses — only the fold changes — to recover *when*
# identity changed (`timeline`) and to time-travel the golden record (`golden_as_of`).
#
# WHAT THE FIXTURE ACTUALLY SHOWS (the honest story) ──────────────────────────────────────────
# `ClaimMapping` folds each source-listing's identity into ONE final-code-set claim, so the temporal
# pass folds over already-folded claims: it dates *when each listing's identity was first recorded*,
# not intra-listing EAN evolution. Every 422156 listing already carries the convergent CNK + GTIN, so
# its timeline is a SINGLE dated mint — a 0→1 "when did it become identified" transition, NOT a 2→1
# merge. And the fold-forward reconcile NEVER auto-merges two established keys: when a late barcode
# bridges them, the gr-ose over-merge guard FLAGS a proposal (auto-merge is a steward action only).
#
#   Block A — real 422156 identity timeline (the single dated mint).
#   Block B — golden as-of, before vs on the mint date (the 0 → 1 transition).
#   Block C — small as-of grid: variant-count per as-of date (the "became identified" step).
#   Block D — SYNTHETIC over-merge guard, temporally: a late bridge of two established keys is FLAGGED.
#
# Stdlib only, no Hex deps. Presentation only — it changes nothing about identity or the engine.

alias GoldenRecord.{Events, Catalog}

defmodule Demo do
  @fixture "test/ingest/fixtures/medipim_be_422156.json"

  def run do
    %{log: log, timeline: timeline} = HistoryEnvelope.load!(@fixture) |> List.wrap() |> Temporal.run()
    mint_date = mint_date(timeline)

    block_a_timeline(timeline)
    block_b_before_after(log, mint_date)
    block_c_grid(log, mint_date)
    block_d_over_merge_guard()

    title("PUNCHLINE")

    IO.puts("""
      A SNAPSHOT says "422156 is one clean product." The TEMPORAL pass adds two honest facts:
        • it dates WHEN 422156 first acquired a resolvable golden identity — #{mint_date}, not earlier;
        • and (Block D) it refuses to SILENTLY merge two established identities a late barcode bridges —
          it flags a proposal, exactly as the v1 over-merge guard (gr-ose) does. Same data, second fold.
    """)
  end

  # ════════════════════════════════════════════════════════════════════════════════════════
  # Block A — the real identity timeline: *when* identity changed. For 422156 this is a single
  # dated mint, because every listing already carries the convergent codes (see the file header).
  defp block_a_timeline(timeline) do
    title("A. IDENTITY TIMELINE — real entity 422156 (when identity changed)")
    print_timeline(timeline)
    IO.puts("\n  -> a SINGLE mint: 422156's golden identity is first resolvable on this date.")
  end

  # ════════════════════════════════════════════════════════════════════════════════════════
  # Block B — golden time-travel across the mint: the honest 0 → 1 transition. Before the mint
  # date no identity claim exists yet, so the product has no resolvable variant; on it, exactly one.
  defp block_b_before_after(log, mint_date) do
    title("B. GOLDEN AS-OF — before vs on the mint date (#{mint_date})")

    before = Date.add(mint_date, -1)
    IO.puts("  as-of #{before} (day before the mint):")
    print_as_of(Temporal.golden_as_of(log, before))

    IO.puts("\n  as-of #{mint_date} (the mint):")
    print_as_of(Temporal.golden_as_of(log, mint_date))
  end

  # ════════════════════════════════════════════════════════════════════════════════════════
  # Block C — a small as-of grid: variant-count per as-of date across the claim history. The step
  # from 0 to 1 IS the temporal signal a flat snapshot throws away.
  defp block_c_grid(log, mint_date) do
    title("C. AS-OF GRID — variant count per as-of date (the 'became identified' step)")

    dates = claim_dates(log)

    grid =
      ([List.first(dates), Date.add(mint_date, -1), mint_date, List.last(dates)] ++ sample(dates, 6))
      |> Enum.uniq()
      |> Enum.sort(Date)

    Enum.each(grid, fn d ->
      n = Temporal.golden_as_of(log, d) |> Enum.flat_map(& &1.variants) |> length()
      step = if d == mint_date, do: "   <-- first identified", else: ""
      IO.puts("    as-of #{d}  ->  #{n} variant(s)#{step}")
    end)

    IO.puts("\n  (rows span the legacy claim history; the 0 -> 1 step is when identity became resolvable)")
  end

  # ════════════════════════════════════════════════════════════════════════════════════════
  # Block D — the over-merge guard, TEMPORALLY (synthetic, because the real fixture never diverges).
  # Two listings establish disjoint keys at d1; a third carries BOTH codes at d2, bridging them. The
  # engine refuses to silently fuse two established identities — it FLAGS a merge proposal instead.
  defp block_d_over_merge_guard do
    title("D. OVER-MERGE GUARD, TEMPORALLY — a late bridge is FLAGGED, not merged (synthetic)")

    d1 = ~D[2024-01-01]
    d2 = ~D[2024-06-01]

    envs = [
      envelope(900, [
        id("C", "gtin", "05000000000017", epoch(d1, 9)),
        id("D", "cnk", "1000000", epoch(d1, 9)),
        id("E", "gtin", "05000000000017", epoch(d2, 9)),
        id("E", "cnk", "1000000", epoch(d2, 9))
      ])
    ]

    %{log: log, timeline: timeline} = Temporal.run(envs)

    IO.puts("  timeline:")
    print_timeline(timeline)

    Enum.each([d1, d2], fn d ->
      keys = Temporal.golden_as_of(log, d) |> Enum.flat_map(& &1.variants) |> Enum.map(& &1.key)
      IO.puts("\n  as-of #{d}: keys #{inspect(Enum.sort(keys))}")
    end)

    IO.puts(
      "\n  -> the bridge at #{d2} is FLAGGED (a merge proposal), the two keys SURVIVE — no silent\n" <>
        "     over-merge, exactly as the v1 guard (gr-ose) refuses to fuse a reused-barcode collision."
    )
  end

  # ── timeline / projection presentation ──────────────────────────────────────────
  defp print_timeline([]), do: IO.puts("    (no identity events)")

  defp print_timeline(timeline) do
    Enum.each(timeline, fn e -> IO.puts("    #{e.recorded_at}  #{timeline_line(e)}") end)
  end

  defp timeline_line(%Events.IdentityMinted{key: k, codes: c}),
    do: "MINT      #{k}  [#{listcodes(c)}]"

  defp timeline_line(%Events.IdentityMembersChanged{key: k, codes: c}),
    do: "MEMBERS   #{k}  [#{listcodes(c)}]"

  defp timeline_line(%Events.IdentitiesMerged{from: from, into: into}),
    do: "MERGE     #{Enum.join(from, ", ")} -> #{into}"

  defp timeline_line(%Events.IdentitySplit{key: k, into: into}),
    do: "SPLIT     #{k} -> #{into |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}"

  defp timeline_line(%Events.ConflictFlagged{subject: {:merge, keys}}),
    do: "FLAG      merge proposal #{inspect(keys)} (gated — never auto-merged)"

  defp timeline_line(%Events.ConflictFlagged{subject: subject}),
    do: "FLAG      #{inspect(subject)}"

  defp print_as_of([]), do: IO.puts("    (no variant — product not yet identified)")

  defp print_as_of(records) do
    Enum.each(records, fn %{product: product, variants: variants} ->
      IO.puts("    product #{inspect(product)}")

      Enum.each(variants, fn v ->
        IO.puts("      variant #{v.key}  [#{listcodes(v.codes)}]#{cnk_suffix(v.codes)}")
      end)
    end)
  end

  # Highlight the canonical CNK out of the variant's codes (golden_as_of is plain Catalog.project,
  # so there is no enriched `:cnk` field — read it back off the codes).
  defp cnk_suffix(codes) do
    case Enum.find(codes, &match?({:cnk, _}, &1)) do
      nil -> ""
      cnk -> "  CNK #{lc(cnk)}"
    end
  end

  defp listcodes(codes) when is_list(codes), do: Enum.map_join(codes, ", ", &lc/1)
  defp listcodes(%MapSet{} = codes), do: codes |> MapSet.to_list() |> Enum.sort() |> listcodes()
  defp lc({scheme, value}), do: "#{scheme}:#{value}"

  # ── derivations off the fixture (computed, never hard-coded) ─────────────────────
  defp mint_date(timeline) do
    %Events.IdentityMinted{recorded_at: d} = Enum.find(timeline, &match?(%Events.IdentityMinted{}, &1))
    d
  end

  defp claim_dates(log),
    do: for(%Events.ClaimAsserted{} = c <- log, do: c.recorded_at) |> Enum.uniq() |> Enum.sort(Date)

  defp sample(dates, n) do
    Enum.take_every(dates, max(1, div(length(dates), n)))
  end

  # ── synthetic-envelope helpers (same terse shape as the ingest tests) ───────────
  defp envelope(entity, events) do
    {:ok, env} =
      HistoryEnvelope.from_map(%{
        "schema_version" => "1",
        "legacy_entity" => entity,
        "events" => events
      })

    env
  end

  defp id(source, scheme, code, at),
    do: %{
      "recorded_at" => at,
      "source" => source,
      "op" => "set",
      "kind" => "identity",
      "scheme" => scheme,
      "code" => code
    }

  defp epoch(%Date{} = date, hour),
    do: date |> DateTime.new!(Time.new!(hour, 0, 0)) |> DateTime.to_unix()

  defp title(t), do: IO.puts("\n" <> String.duplicate("─", 100) <> "\n  " <> t <> "\n")
end

Demo.run()
