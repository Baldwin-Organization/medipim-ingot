alias GoldenRecord.{Events}

defmodule Api.Cutover do
  @moduledoc """
  `POST /v1/cutover` (gr-w4l): commit a migration batch — the explicit cutover of the
  dry-run → fix mapping → repeat → cutover loop (design §3).

  DECISION — a third write endpoint, not documented `/v1/claims` semantics. Two reasons,
  both visible in the code rather than aspirational:

    1. **Convergence needs compaction.** `/v1/claims` is append-oriented: a batch may
       legitimately carry several updates to one slot, and each lands in the log. A migration
       batch derived from a legacy delta history does exactly that — and under append semantics
       an identical re-run is NOT convergent: the non-final values of each slot fail the
       `asserted?` skip, get re-appended, and the last append wins, flipping the current value
       back to an older one. A cutover batch is therefore declared to be the source's CURRENT
       truth: only the last claim per slot counts (`Api.Writes.simulate(…, compact: true)`),
       which makes identical re-runs exact no-ops (zero events, zero key churn) and changed
       re-runs supersede only their own slots. History replays belong to
       `POST /v1/backfill/envelopes`, which carries real historical `recorded_at`.
    2. **The response must be diffable against the dry-run.** `/v1/claims` answers the writer
       summary; the operator cutting over needs the migration report — the same sections the
       dry-run predicted (`Api.DryRun.sections/2`: mints, merge candidates, conflicts,
       collisions, the seeded steward queue), now describing the committed world, plus
       `lineage`: the legacy-id assignments this commit recorded (minted surrogate keys → the
       legacy ids downstream systems keep using).

  Everything runs inside ONE writer transaction: simulate against the locked state, append the
  exact events the simulation stamped (`Store.insert_and_fold` re-assigns the same offsets from
  the same state), render the report from `would_state` — which by construction IS the committed
  state. A batch the validator rejects answers `422` like `/v1/claims`; a cutover commits whole
  or not at all.

  Report framing: `cutover: true`, `committed: true`, `counts.compacted` (claims dropped as
  non-final slot history), `lineage`, and a past-tense summary line. Everything else is shaped
  exactly like the dry-run report, so the two diff cleanly.
  """

  def commit(claim_maps) do
    Api.Store.append(fn state, _conn ->
      case Api.Writes.simulate(state, claim_maps, compact: true) do
        {:error, errors} -> {:error, {422, %{errors: errors}}}
        {:ok, outcome} -> {:ok, outcome.events, report(state, outcome)}
      end
    end)
  end

  defp report(state, outcome) do
    sections = Api.DryRun.sections(state, outcome)
    counts = Map.put(sections.counts, :compacted, outcome.compacted)

    Map.merge(sections, %{
      cutover: true,
      committed: true,
      counts: counts,
      lineage: lineage(outcome.events),
      summary: committed_line(counts)
    })
  end

  # the lineage THIS commit recorded — empty on a convergent re-run
  defp lineage(events) do
    for %Events.LegacyIdAssigned{key: key, legacy_id: id} <- events do
      %{key: key, legacy_id: id}
    end
  end

  defp committed_line(c) do
    "cutover committed: #{c.accepted} claim(s) accepted " <>
      "(#{c.skipped} skipped, #{c.compacted} compacted); " <>
      "#{c.mints} product(s) minted; " <>
      "#{c.conflicts} conflict(s), #{c.merge_candidates} merge candidate(s) " <>
      "(#{c.suspect_merge_candidates} suspect), #{c.code_collisions} code collision(s) — " <>
      "#{c.steward_queue} item(s) seeded for the steward queue"
  end
end
