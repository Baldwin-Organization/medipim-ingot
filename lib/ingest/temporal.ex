# lib/ingest/temporal.ex — the temporal pass: identity timeline + bitemporal golden as-of (gr-a2j).
#
# T1 of the temporal-pass epic (gr-nh0), the first post-PoC follow-up promised as "Temporal pass
# (follow-up, not v1)" in docs/plans/2026-06-05-legacy-history-ingest-design.md and designed in
# docs/plans/2026-06-09-temporal-pass-design.md. PURELY ADDITIVE: it touches neither the engine
# (golden_record_core.ex) nor any v1 ingest module. It is a SECOND fold over the very same claims
# `ClaimMapping.build/1` already produces — only the fold changes.
#
# WHY A SECOND FOLD ───────────────────────────────────────────────────────────────────────────
# v1 (`Rederivation` -> `GoldenRecords`) folds each legacy listing to its FINAL code-set — a
# snapshot — and projects via the Date-free `Catalog.project` (recency by integer `order`),
# precisely because the legacy envelopes carry INTEGER Unix-epoch timestamps and the engine's
# `History.*` / `Api.*` Date filters raise on integers. A snapshot answers "what is this product
# now?" but discards WHEN identity changed. The temporal pass recovers that: an entity that ends up
# merged may only have BECOME one product over time.
#
# THE BOUNDARY DATE CONVERSION (the load-bearing choice) ───────────────────────────────────────
# Rather than temporalize the engine, we convert epoch -> `Date` ONCE here, at the ingest boundary,
# so the engine's tested `History.project_as_of/3` runs UNCHANGED over a fully Date-typed log
# (golden_record_core.ex stays Date-pure — zero blast radius on existing demos/tests). Each claim's
# integer `recorded_at`/`valid_from` becomes `DateTime.from_unix!(epoch) |> DateTime.to_date()`.
#
# UNI-TEMPORAL — `valid_from = recorded_at`. Legacy deltas carry a SINGLE clock, so we collapse to
# one axis: `project_as_of` ("as known on date D"), not a true two-axis bitemporal grid. Honest to
# the data; the engine's full bitemporal API stays available if a second clock ever appears.
#
# FOLD-FORWARD + STABLE KEYS ──────────────────────────────────────────────────────────────────
# We re-cluster at each distinct date by FOLDING FORWARD, threading the PRIOR ledger into the next
# date's `IdentityLedger.decide/2`. Threading `ledger_prev` is what keeps surrogate keys STABLE
# across time (`decide` continues `next` from the prior ledger and reuses overlapping keys) — the
# whole point: a snapshot-then-diff would reshuffle keys and make the timeline unreadable. This is
# idiomatic — it is exactly what `golden_record_ddd.exs` already does across hand-picked dates. The
# event vocabulary is the engine's existing one (Minted / MembersChanged / Merged / Split) — no new
# event types.
#
# `shared` COMPUTED ONCE — from the FULL history, not per-date. Globally correct: it avoids an early
# reconcile mis-bridging a code before its later reuse is visible.
#
# DAY GRANULARITY does NOT corrupt values. Epoch -> `Date` collapses sub-day deltas onto one
# temporal point, but BOTH same-day updates stay in the log with distinct integer `order`, and
# survivorship picks the winner by `Enum.max_by(.., & &1.order)` — INTEGER `order`, NOT the Date
# (golden_record_core.ex lines 181/210). So same-day updates resolve to the correct END-OF-DAY value
# (the later one wins any shared field); all that is lost is the ability to time-travel to the
# intra-day midpoint. Because resolution keys off `order` not Date, collapsing to days CANNOT change
# any resolved value — which is also why the temporal fold converges to the v1 snapshot at "today"
# (v1's `Catalog.project` uses the same `order`-based recency).
#
# OUTPUT — `temporal_log = date_stamped_claims ++ all_dated_identity_events`, re-`order`-stamped
# monotonic (mirroring v1's `Rederivation.stamp/2`: continue order after the max claim order,
# preserving emission order). The log is fully Date-typed, so the engine's read layer folds it
# unchanged: `golden_as_of/3` is a thin pass-through to `History.project_as_of/3`.
#
# SCOPE BOUNDARY: this bead OWNS only this module. The ExUnit suite (gr-qka, test/ingest/
# temporal_test.exs) and the runnable demo (gr-aqb, temporal_ingest.exs) are SEPARATE beads that
# dispatch after this one lands — creating them here would collide on those files.

defmodule Temporal do
  @moduledoc """
  The temporal pass: a second fold over the ingest's claims that recovers *when* identity changed.

  Where v1 (`Rederivation` → `GoldenRecords`) folds each legacy listing to a final snapshot, this
  folds forward across the distinct dates — converting epoch timestamps to `Date`s at the boundary
  and threading the prior ledger so surrogate keys stay stable — producing a fully `Date`-typed
  temporal log that the engine's `History.project_as_of/3` reads unchanged. See the file header
  above for the full design rationale.
  """

  @doc """
  Run the temporal pass over a list of `%HistoryEnvelope{}`s.

  Builds claims via `ClaimMapping.build/1`, converts their integer-epoch timestamps to `Date`s at
  the boundary, then folds forward across the distinct dates — threading the prior ledger so
  surrogate keys stay stable — emitting *dated* identity events.

  Returns `%{log: temporal_log, timeline: [identity events], ledger: %IdentityLedger{}}`, where:

    * `log` — the temporal event log (`date-stamped claims ++ dated identity events`), re-`order`-
      stamped monotonic and fully `Date`-typed, so the engine's read layer folds it unchanged. Feed
      it to `golden_as_of/3`.
    * `timeline` — the dated identity events (mint / members-changed / merge / split), sorted by
      `{recorded_at, order}` — *when* identity changed.
    * `ledger` — the final `%IdentityLedger{}` after folding through every date.
  """
  def run(envelopes) when is_list(envelopes) do
    %{claims: raw_claims, shared: shared} = ClaimMapping.build(envelopes)

    # Boundary conversion: epoch -> Date, ONCE, on a copy of v1's claims (v1's path is untouched).
    # valid_from = recorded_at (uni-temporal); integer `order` preserved for within-day sequencing.
    claims =
      Enum.map(raw_claims, fn claim ->
        date = to_date(claim.recorded_at)
        # valid_to is the one field that is NOT collapsed onto recorded_at: an identity claim now
        # covers a period, and its end is a real second clock value that has to cross the boundary
        # too. Leaving it as an epoch put a Date and an integer on the same claim.
        %{claim | recorded_at: date, valid_from: date, valid_to: claim.valid_to && to_date(claim.valid_to)}
      end)

    dates = claims |> Enum.map(& &1.recorded_at) |> Enum.uniq() |> Enum.sort(Date)

    {raw_identity_events_rev, _ledgers} =
      Enum.reduce(dates, {[], Lanes.new_ledgers()}, fn d, {events_acc, ledgers_prev} ->
        live_d =
          claims
          |> Enum.filter(&(Date.compare(&1.recorded_at, d) != :gt))
          |> Substrate.current()

        # Per-lane reconcile (gr-2a8): description/media identity claims fold against their own
        # ledgers, so the temporal product timeline never mints product keys for them.
        {events_d, ledgers_d} = Lanes.reconcile(live_d, shared, ledgers_prev, d)

        # Prepend (reverse onto the acc), then reverse once after the fold — avoids O(n²) `++` growth.
        {Enum.reverse(events_d, events_acc), ledgers_d}
      end)

    raw_identity_events = Enum.reverse(raw_identity_events_rev)
    ledger = Enum.reduce(raw_identity_events, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1))

    # `decide` leaves identity events with `order: nil`; stamp them monotonic, continuing after the
    # max claim order (mirrors Rederivation.stamp/2). Stamp ONCE here so the timeline and the log
    # carry the SAME orders — the timeline is just these stamped events, re-sorted by {date, order}.
    identity_events = stamp(raw_identity_events, claims)
    log = claims ++ identity_events

    # The timeline narrates the PRODUCT lane (the time machine's subject); other lanes' identity
    # events stay in the log, where the read layer and Catalog's edge traversal find them.
    timeline =
      identity_events
      |> Enum.filter(&product_lane_event?/1)
      |> Enum.sort_by(&{&1.recorded_at, &1.order}, &date_order/2)

    %{log: log, timeline: timeline, ledger: ledger}
  end

  # Merges/splits never cross lanes (disjoint folds), so the anchor key's lane is the event's.
  defp product_lane_event?(event) do
    key =
      case event do
        %Events.IdentityMinted{key: k} -> k
        %Events.IdentityMembersChanged{key: k} -> k
        %Events.IdentitiesMerged{into: k} -> k
        %Events.IdentitySplit{key: k} -> k
        _ -> nil
      end

    key == nil or Lanes.lane_of_key(key) == :product
  end

  @doc """
  Project the golden record as it was KNOWN on `date`, from a temporal `log` (the `:log` of
  `run/1`). A thin pass-through to the engine's `History.project_as_of/3`, foldable because the
  temporal log is fully `Date`-typed.

  `priority` is a `%Priority{}`; it defaults to the same permissive `Priority.new(%{}, [])` as
  `GoldenRecords` — every source unranked, so a genuine multi-source disagreement surfaces honestly
  as `:needs_review` rather than silently picking a winner. Callers that DO have a ranking pass
  their own `%Priority{}`.
  """
  def golden_as_of(log, date, priority \\ default_priority()) do
    History.project_as_of(log, date, priority)
  end

  @doc "The permissive default priority — every source unranked, so conflicts tie (see `golden_as_of/3`)."
  def default_priority, do: Priority.new(%{}, [])

  # epoch (integer Unix seconds) -> Date, at the ingest boundary.
  defp to_date(epoch) when is_integer(epoch), do: epoch |> DateTime.from_unix!() |> DateTime.to_date()

  # Continue the identity events' `:order` after the highest claim order, preserving emission order,
  # so the combined temporal log stays monotonically sequenced for the engine's read layer.
  # Mirrors `Rederivation.stamp/2`.
  defp stamp(events, claims) do
    base = claims |> Enum.map(& &1.order) |> Enum.max(fn -> -1 end)

    events
    |> Enum.with_index(base + 1)
    |> Enum.map(fn {event, order} -> %{event | order: order} end)
  end

  # Comparator for `{%Date{}, order}` tuples: Date first (Date.compare), then integer order.
  defp date_order({date_a, order_a}, {date_b, order_b}) do
    case Date.compare(date_a, date_b) do
      :lt -> true
      :gt -> false
      :eq -> order_a <= order_b
    end
  end
end
