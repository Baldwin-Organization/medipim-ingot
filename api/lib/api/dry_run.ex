alias GoldenRecord.{Events, Lanes, Stewardship}

defmodule Api.DryRun do
  @moduledoc """
  `POST /v1/dry-run` (gr-rlq): the FULL claims pipeline — validate → canonicalize → cluster →
  reconcile — run against the current state with NOTHING committed, shaped as the migration
  report: the funnel artifact ("1,400 conflicts, 230 merge candidates") plus per-item drill-down.

  `Api.Writes.simulate/2` runs the exact `claims/1` pipeline uncommitted, so the verdicts here
  are byte-for-byte what a real `POST /v1/claims` of the same batch would produce; this module
  only projects the would-be state and renders. Sections (every key always present):

    * `validation`       — per-index contract violations (what `/v1/claims` would 422 with).
    * `submission`       — the exact response `/v1/claims` WOULD return (accepted / skipped /
                           events / flagged); `null` when validation rejected the batch.
    * `mints`            — keys this batch would mint, with their codes.
    * `merge_candidates` — open merge proposals in the WOULD-BE state (the over-merge guard
                           gates these — established keys never auto-merge); `suspect: true`
                           when a key is bridged solely by barcode-grade codes (reusable GS1
                           codes — weak evidence, mirroring `LegacyXref`'s guard); `new: true`
                           marks the proposals THIS batch raises.
    * `conflicts`        — attribute contradictions per `(key, field)` dimension, with every
                           source's candidate value; `counts.conflicts_by_field` rolls them up
                           per dimension.
    * `code_collisions`  — variants whose grouping claims point at more than one product.
    * `steward_queue`    — the undecidables: every open item a steward would have to work
                           (merge proposals + attribute ties + collisions, minus anything
                           already resolved).
  """

  @doc "Build the dry-run migration report for a decoded claims batch. Commits nothing."
  def report(claim_maps) do
    state = Api.Store.state()

    # compact: true matches the cutover this dry-run predicts (gr-dfp) — a slot's non-final
    # history must not survive into the accepted count, or a dry-run AFTER a cutover of the same
    # batch would report accepted > 0 where the cutover compacted to a no-op.
    case Api.Writes.simulate(state, claim_maps, compact: true) do
      {:error, errors} ->
        rejected(errors)

      {:ok, outcome} ->
        sections = sections(state, outcome)

        Map.merge(sections, %{
          dry_run: true,
          would_commit: true,
          summary: funnel_line(sections.counts)
        })
    end
  end

  # ── the two report shapes ────────────────────────────────────────────────────
  defp rejected(errors) do
    %{
      dry_run: true,
      would_commit: false,
      summary:
        "batch rejected: #{length(errors)} validation error(s) — nothing would be committed",
      counts: counts(%{validation_errors: length(errors)}),
      validation: %{errors: errors},
      submission: nil,
      mints: [],
      merge_candidates: [],
      conflicts: [],
      code_collisions: [],
      steward_queue: []
    }
  end

  @doc """
  The report sections shared by both flavors — the dry-run (`report/1`) and the committed cutover
  (`Api.Cutover`): counts + mints / merge_candidates / conflicts / code_collisions /
  steward_queue, computed from `outcome.would_state`. For the cutover, `would_state` IS the
  committed state (same events, same offsets, same writer lock), so the sections describe exactly
  what the commit did. Framing keys (`dry_run`/`committed`/`summary`/…) are the caller's.
  """
  def sections(state, %{summary: submission, identity_events: ievents, would_state: would}) do
    today = Date.utc_today()
    claims = Api.State.current_claims(would)
    members = would.ledger.members

    mints =
      for %Events.IdentityMinted{key: key, codes: c, recorded_at: at} <- ievents,
          Lanes.lane_of_key(key) == :product do
        %{key: key, codes: codes(c), date: Date.to_iso8601(at)}
      end

    already_open = MapSet.new(Api.State.open_flags(state), & &1.subject)

    merge_candidates =
      for %Events.ConflictFlagged{subject: {:merge, keys}, candidates: cluster} <-
            Api.State.open_flags(would) do
        %{
          keys: keys,
          bridge: codes(cluster),
          suspect: suspect?(claims, members, would.shared, keys, cluster),
          members: Map.new(keys, fn k -> {k, codes(Map.get(members, k, MapSet.new()))} end),
          new: not MapSet.member?(already_open, {:merge, keys})
        }
      end

    conflicts =
      for %Events.ConflictFlagged{subject: {:attr, key, field} = subject, candidates: cands} <-
            Stewardship.detect(members, claims, Api.Priority.current(), today),
          not MapSet.member?(would.resolved, subject) do
        %{
          key: key,
          field: to_string(field),
          candidates: Enum.map(cands, fn {s, v} -> %{source: to_string(s), value: v} end)
        }
      end

    code_collisions =
      for %Events.ConflictFlagged{subject: {:collision, key} = subject, candidates: prods} <-
            Stewardship.detect_collisions(members, claims, today),
          not MapSet.member?(would.resolved, subject) do
        %{
          key: key,
          codes: codes(Map.get(members, key, MapSet.new())),
          products:
            Enum.map(prods, fn %{source: s, product: p} -> %{source: to_string(s), product: p} end)
        }
      end

    steward_queue =
      Enum.map(merge_candidates, &queue_item("merge", {:merge, &1.keys})) ++
        Enum.map(conflicts, &queue_item("attribute", {:attr, &1.key, &1.field})) ++
        Enum.map(code_collisions, &queue_item("collision", {:collision, &1.key}))

    counts =
      counts(%{
        claims: submission.claims,
        accepted: submission.accepted,
        skipped: submission.skipped,
        mints: length(mints),
        conflicts: length(conflicts),
        conflicts_by_field: Enum.frequencies_by(conflicts, & &1.field),
        merge_candidates: length(merge_candidates),
        suspect_merge_candidates: Enum.count(merge_candidates, & &1.suspect),
        code_collisions: length(code_collisions),
        steward_queue: length(steward_queue)
      })

    %{
      counts: counts,
      validation: %{errors: []},
      submission: submission,
      mints: mints,
      merge_candidates: merge_candidates,
      conflicts: conflicts,
      code_collisions: code_collisions,
      steward_queue: steward_queue
    }
  end

  # ── classification ───────────────────────────────────────────────────────────
  # Over-merge-guard tagging, mirroring `LegacyXref`'s `:suspect` relation. The proposal's
  # `cluster` is the UNION of every connected code-set, so a key's own codes are always in it —
  # the actual bridge is the set of LISTINGS (live identity claims) that span beyond a key. Per
  # key: the codes through which bridging listings attach to it. If any key is attached SOLELY
  # through barcode-grade codes (reusable/reassignable GS1 codes — `CodeRegistry`'s bridge-grade
  # axis), the evidence is weak and the candidate is SUSPECT. A national code on every link
  # keeps the proposal trusted (still gated — established keys never auto-merge).
  defp suspect?(claims, members, shared, keys, cluster) do
    bare_cluster = MapSet.difference(cluster, shared)

    listing_codes =
      for c <- claims, c.kind == :identity do
        MapSet.difference(MapSet.new(c.data.codes), shared)
      end

    Enum.any?(keys, fn key ->
      owned = members |> Map.get(key, MapSet.new()) |> MapSet.difference(shared)
      outside = MapSet.difference(bare_cluster, owned)

      attachment =
        listing_codes
        |> Enum.filter(fn codes ->
          not MapSet.disjoint?(codes, owned) and not MapSet.disjoint?(codes, outside)
        end)
        |> Enum.reduce(MapSet.new(), &MapSet.union(&2, MapSet.intersection(&1, owned)))

      not Enum.any?(attachment, fn {scheme, _} -> CodeRegistry.national_grade?(scheme) end)
    end)
  end

  # ── rendering ────────────────────────────────────────────────────────────────
  defp queue_item(type, subject), do: %{type: type, subject: Api.Views.subject(subject)}

  defp codes(set), do: set |> Enum.sort() |> Enum.map(&Api.Views.code/1)

  @zero %{
    claims: 0,
    accepted: 0,
    skipped: 0,
    validation_errors: 0,
    mints: 0,
    conflicts: 0,
    conflicts_by_field: %{},
    merge_candidates: 0,
    suspect_merge_candidates: 0,
    code_collisions: 0,
    steward_queue: 0
  }

  defp counts(overrides), do: Map.merge(@zero, overrides)

  # The one-line funnel artifact (design §2): pain, quantified.
  defp funnel_line(c) do
    "#{c.accepted} claim(s) would be accepted (#{c.skipped} skipped); " <>
      "#{c.mints} product(s) would be minted; " <>
      "#{c.conflicts} conflict(s), #{c.merge_candidates} merge candidate(s) " <>
      "(#{c.suspect_merge_candidates} suspect), #{c.code_collisions} code collision(s) — " <>
      "#{c.steward_queue} item(s) for the steward queue"
  end
end
