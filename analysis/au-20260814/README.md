# AU export quality sweep — 2026-08-14

Quality measurement of the medipim **AU** delta export (`prod-lu-20260814.csv`, 713 MB —
filename says LU, content is AU; kept in `~/Downloads/`, NOT committed). Findings and
follow-ups in `au-quality-report.md`; the beads under the `au-quality` epic track the work.

| file | what |
|------|------|
| `au-quality-report.md` | The report: registry gaps, identity health, replacement lifecycle, unit-noise ties, 587 GTIN collisions. |
| `au_collisions.json` | All 587 canonical codes live-claimed by >1 entity — the pre-migration review queue. |
| `au_quality.json` | Per-entity metrics for the 500-entity cohort (worst-20, failures, summary). |
| `cohort.json` / `entity_stats.json` | The 500 chosen entities (350 churniest + 150 random) and their raw stats. |
| `preflight.py` | Pass 1: streaming field census + churn stats over the full CSV. |
| `extract_cohort.py` | Pass 2: writes one `raw.jsonl` per cohort entity. |
| `dupes.py` | Cross-entity live code-ownership scan (the collision list). |
| `sweep.exs` | The Elixir sweep: `gen.exs` decode → `Temporal.run` → `LegacyXref` → aggregate (run via `mix run`). |

Reproduce: run the three Python scripts then `mix run sweep.exs`. NOTE: scripts carry
absolute paths (the session scratchpad + `~/Downloads` CSV) — adjust the constants at the
top of each before rerunning. Decoded envelopes (`au_env/`, ~7 MB × 500) are regenerable,
not committed.
