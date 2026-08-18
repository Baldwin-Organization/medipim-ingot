# lib/ingest/migration_diff.ex — the migration-validation diff VIEW (gr-swc).
#
# Stage 4c of the legacy-medipim ingest, AFTER LegacyXref (gr-0c2). The design promises the
# migration diff "for free" because LegacyXref's `legacy_to_key` relation already IS the
# confirm/merge/split classification and `PublicId.collisions(:cnk, log)` already IS the
# hard-invariant (collision) check. This module is ONLY the VIEW: it READS those two existing
# projections and RENDERS them — as a machine JSON form and a human summary string. It changes
# NOTHING about identity, clustering, or the engine; it is a pure fold over data others produced.
#
# CONFIDENCE — the load-bearing distinction a migrator acts on:
#
#   :stable                      -> :confirmed  (1:1)                       confidence :high
#   {:merged, others}            -> :merged     (a national CNK bridged)    confidence :high
#   {:merged, others, :suspect}  -> :merged + needs_review                  confidence :low
#                                   (only a BARCODE bridged — see gr-ose; the cross-org GTIN/EAN
#                                    bridge is weaker evidence than a national code, so a human
#                                    should eyeball it before trusting the merge)
#   :split                       -> :split (the entity FRAGMENTED across keys; list all + primary)
#   PublicId.collisions(:cnk)    -> :collision + needs_review (a CNK on >1 key — an invariant
#                                    VIOLATION, never expected; always surfaces for review)
#
# JSON-SAFETY: codes are engine tuples (`{:cnk, "100"}`) and the built-in `JSON` module cannot
# encode tuples. So findings carry codes as `"scheme:value"` strings and relations as plain maps
# from the start — the report map is JSON-safe by construction, and `to_json/1` is a thin
# `JSON.encode!`. (Atoms encode as strings via the built-in encoder, which is exactly what we want
# for the category/confidence enums.)
#
# SCOPE BOUNDARY: this bead OWNS only this module + its test. It does NOT edit legacy_xref.ex or
# code_registry.ex (gr-ose owns those this wave) — it consumes the `:suspect` relation variant they
# emit purely as input.

alias GoldenRecord.{PublicId}

defmodule MigrationDiff do
  @doc """
  Build the migration-diff report from a re-derivation result `%{log: log, ledger: ledger}` (the
  map returned by `Rederivation.run/2` / `Rederivation.from_claims/2`).

  Internally folds `LegacyXref.build/1`'s `legacy_to_key` and `PublicId.collisions(:cnk, log)` into
  one structured, JSON-safe report:

      %{
        findings: [finding, ...],            # sorted: legacy findings (by entity), then collisions
        counts: %{confirmed: n, merged: n, split: n, collision: n, needs_review: n},
        needs_review: [finding, ...]         # the suspect merges + CNK collisions, for the summary
      }

  Each `finding` is one of:

      # :stable
      %{category: "confirmed", legacy_entity: ent, keys: ["SK_n"], primary: "SK_n",
        relation: "stable", evidence: %{...}, confidence: "high", needs_review: false}

      # {:merged, others}            (trusted — a national code bridged)
      %{category: "merged", legacy_entity: ent, keys: ["SK_n"], primary: "SK_n",
        relation: "merged", evidence: %{merged_with: [other, ...]},
        confidence: "high", needs_review: false}

      # {:merged, others, :suspect}  (barcode-only bridge — see gr-ose)
      %{category: "merged", ..., evidence: %{merged_with: [...], bridge: "barcode"},
        confidence: "low", needs_review: true}

      # :split
      %{category: "split", legacy_entity: ent, keys: ["SK_a", "SK_b"], primary: "SK_a",
        relation: "split", evidence: %{fragments: ["SK_a", "SK_b"]},
        confidence: "high", needs_review: false}

      # PublicId.collisions(:cnk)
      %{category: "collision", code: "cnk:100", keys: ["SK_a", "SK_b"],
        relation: "collision", evidence: %{collided_keys: [...]},
        confidence: "low", needs_review: true}
  """
  def build(%{log: log} = rederivation) do
    %{legacy_to_key: legacy_to_key} = LegacyXref.build(rederivation)
    render(legacy_to_key, PublicId.collisions(:cnk, log))
  end

  @doc """
  Convenience: run `Rederivation.run(envelopes, at)` internally, then `build/1` its result, for
  callers holding raw `%HistoryEnvelope{}`s rather than a re-derivation map.
  """
  def from_envelopes(envelopes, at) when is_list(envelopes) do
    envelopes |> Rederivation.run(at) |> build()
  end

  @doc """
  The pure renderer underneath `build/1`: turn a `legacy_to_key` map (LegacyXref's relation
  taxonomy) and a `PublicId.collisions(:cnk, log)` list straight into the report. Exposed so the
  rendering can be exercised against a hand-assembled placement (e.g. the `{:merged, [..], :suspect}`
  variant gr-ose emits) without round-tripping through the engine.
  """
  def render(legacy_to_key, collisions) do
    legacy_findings =
      legacy_to_key
      |> Enum.sort_by(fn {entity, _} -> entity end)
      |> Enum.map(fn {entity, placement} -> legacy_finding(entity, placement) end)

    findings = legacy_findings ++ Enum.map(collisions, &collision_finding/1)

    %{
      findings: findings,
      counts: counts(findings),
      needs_review: Enum.filter(findings, & &1.needs_review)
    }
  end

  @doc """
  Render the report (`build/1`) as a machine-readable JSON string via the built-in `JSON` module.
  The report is JSON-safe by construction (no tuples), so this round-trips through `JSON.decode/1`.
  """
  def to_json(report), do: JSON.encode!(report)

  @doc """
  Render the report (`build/1`) as a human-readable multi-line summary: a count per category, then
  an explicit, itemized list of every needs-review finding (the suspect/barcode-only merges and the
  CNK collisions) so a migrator sees exactly what to eyeball.
  """
  def to_summary(%{counts: counts, needs_review: needs_review}) do
    header = [
      "Migration diff",
      "  confirmed:    #{counts.confirmed}",
      "  merged:       #{counts.merged}",
      "  split:        #{counts.split}",
      "  collision:    #{counts.collision}",
      "  needs review: #{counts.needs_review}"
    ]

    review_lines =
      case needs_review do
        [] -> ["", "No findings need review."]
        items -> ["", "Needs review (#{length(items)}):" | Enum.map(items, &review_line/1)]
      end

    Enum.join(header ++ review_lines, "\n")
  end

  # ── classification ───────────────────────────────────────────────────────────

  defp legacy_finding(entity, %{primary: primary, all: all, relation: :stable}) do
    %{
      category: "confirmed",
      legacy_entity: entity,
      keys: all,
      primary: primary,
      relation: "stable",
      evidence: %{},
      confidence: "high",
      needs_review: false
    }
  end

  defp legacy_finding(entity, %{primary: primary, all: all, relation: {:merged, others}}) do
    %{
      category: "merged",
      legacy_entity: entity,
      keys: all,
      primary: primary,
      relation: "merged",
      evidence: %{merged_with: others},
      confidence: "high",
      needs_review: false
    }
  end

  defp legacy_finding(entity, %{primary: primary, all: all, relation: {:merged, others, :suspect}}) do
    %{
      category: "merged",
      legacy_entity: entity,
      keys: all,
      primary: primary,
      relation: "merged",
      evidence: %{merged_with: others, bridge: "barcode"},
      confidence: "low",
      needs_review: true
    }
  end

  defp legacy_finding(entity, %{primary: primary, all: all, relation: :split}) do
    %{
      category: "split",
      legacy_entity: entity,
      keys: all,
      primary: primary,
      relation: "split",
      evidence: %{fragments: all},
      confidence: "high",
      needs_review: false
    }
  end

  defp collision_finding(%{code: code, keys: keys}) do
    %{
      category: "collision",
      code: render_code(code),
      keys: keys,
      relation: "collision",
      evidence: %{collided_keys: keys},
      confidence: "low",
      needs_review: true
    }
  end

  # ── rendering helpers ─────────────────────────────────────────────────────────

  # An engine code tuple `{:cnk, "100"}` -> a JSON-safe `"cnk:100"` string.
  defp render_code({scheme, value}), do: "#{scheme}:#{value}"

  defp counts(findings) do
    freq = Enum.frequencies_by(findings, & &1.category)

    %{
      confirmed: Map.get(freq, "confirmed", 0),
      merged: Map.get(freq, "merged", 0),
      split: Map.get(freq, "split", 0),
      collision: Map.get(freq, "collision", 0),
      needs_review: Enum.count(findings, & &1.needs_review)
    }
  end

  defp review_line(%{category: "merged", legacy_entity: entity, primary: primary} = f) do
    others = f.evidence |> Map.get(:merged_with, []) |> Enum.join(", ")

    "  - merged (suspect): legacy #{entity} -> #{primary} with [#{others}] (barcode-only bridge, confidence low)"
  end

  defp review_line(%{category: "collision", code: code, keys: keys}) do
    "  - collision: #{code} owns keys [#{Enum.join(keys, ", ")}] (CNK invariant violation)"
  end
end
