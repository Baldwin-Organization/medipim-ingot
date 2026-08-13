# lib/ingest/finer_claims.ex — the finer-grained per-event identity fold (gr-apd).
#
# Promotes the prototype from temporal_export.exs into a supported ingest mode, for the Product
# API backfill (docs/plans/2026-06-10-medipim-product-api-design.md, T1).
#
# WHY FINER ─────────────────────────────────────────────────────────────────────────────────────
# `ClaimMapping.build/1` collapses each listing (entity, source) to its FINAL code-set, stamped at
# the listing's LATEST identity date — so the temporal fold over those claims can only recover when
# each LISTING was last touched, not how its identity evolved. Real entity 422156 loses its whole
# arc that way (a single mint instead of "org 44 diverges for years, then converges"). This module
# folds FINER: after EVERY raw identity event it emits the listing's accumulated code-set as an
# identity claim at that event's TRUE date. The same cluster + fold-forward then recovers the real
# arc — and when a late code bridges two ESTABLISHED keys, the over-merge guard gates a proposal
# instead of silently fusing (the batch fold, with no prior keys, would just see one cluster).
#
# WHAT IT SHARES ────────────────────────────────────────────────────────────────────────────────
# Delta semantics (`apply_identity`), canonicalization (`engine_codes`), anchoring (`primary`),
# never-bridge rules (`shared?`), attribute field naming (`field_dim`), lane-reference folding
# (`lane_refs`), and the lane-collection table (`lane_collections`) are ClaimMapping's —
# exposed `@doc false` and called here, so the two folds cannot drift.
#
# DATE-TYPED THROUGHOUT — epoch -> Date at the boundary (like Temporal), valid_from = recorded_at
# (legacy deltas carry one clock). The engine's History/Api read layers fold the output unchanged.
#
# ANCHORING evolves with the fold: an attribute/edge event anchors to its listing's primary code
# AS OF that event (the running snapshot), falling back to the listing's FINAL primary when the
# listing has no codes yet — data is never dropped just because identity arrived later.

defmodule FinerClaims do
  @moduledoc """
  Per-event identity fold over `%HistoryEnvelope{}`s: one dated identity claim per (listing,
  identity event), preserving the real evolution `ClaimMapping.build/1` collapses away.

  `build/1` produces the Date-typed claim log + `shared` set; `fold_forward/3` reconciles it
  date by date, threading a (possibly pre-existing) ledger so surrogate keys stay stable —
  the increment the Product API uses for both backfill and live claims.
  """

  # ClaimMapping's wire-spelling table, atom-typed for this module's Date-typed claims —
  # derived, not duplicated, so a lane-collection change lands once.
  @lane_collections Map.new(ClaimMapping.lane_collections(), fn {k, {scheme, lane, relation}} ->
                      {k, {String.to_atom(scheme), String.to_atom(lane), String.to_atom(relation)}}
                    end)

  @doc """
  Map envelopes to `%{claims: [%Events.ClaimAsserted{}], shared: MapSet}` — like
  `ClaimMapping.build/1` but with per-event identity granularity and `Date`-typed stamps.

  Identity snapshots that transition to an empty code-set are kept as withdrawals; empty deltas
  before a listing ever had codes are skipped. Consecutive identical snapshots are deduplicated
  (a raw delta that does not change the canonical code-set adds no information).
  """
  def build(envelopes) when is_list(envelopes) do
    per_listing = listing_folds(envelopes)

    identity =
      for %{entity: e, source: s, snapshots: snaps} <- per_listing, {codes, date} <- snaps do
        Substrate.claim(s, :identity, %{ref: "#{e}:#{s}", codes: Enum.sort(codes)}, date, date)
      end

    grouping =
      for %{entity: e, source: s, snapshots: snaps} <- per_listing,
          {codes, date} <- snaps,
          code <- Enum.sort(codes) do
        Substrate.claim(s, :grouping, %{code: code, product: e}, date, date)
      end

    anchors = anchor_index(per_listing)

    attribute =
      for env <- envelopes,
          ev <- env.events,
          ev.kind == :attribute,
          a = anchors.(env.legacy_entity, ev.source, ev.recorded_at),
          a != nil do
        Substrate.claim(
          ev.source,
          :attribute,
          %{code: a, field: ClaimMapping.field_dim(ev), value: ev.data.value},
          to_date(ev.valid_from),
          to_date(ev.recorded_at)
        )
      end

    member_of =
      for env <- envelopes,
          ev <- env.events,
          ev.kind == :edge,
          ev.op in [:set, :add],
          ev.data.value != nil,
          not Map.has_key?(@lane_collections, ev.data.collection),
          a = anchors.(env.legacy_entity, ev.source, ev.recorded_at),
          a != nil do
        Substrate.claim(
          ev.source,
          :member_of,
          %{member_code: a, collection: {ev.data.collection, to_string(ev.data.value)}},
          to_date(ev.valid_from),
          to_date(ev.recorded_at)
        )
      end

    lane_entities =
      envelopes
      |> ClaimMapping.lane_refs()
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.flat_map(fn {{entity, source, collection}, %{ids: ids, last: last}} ->
        {scheme, lane, relation} = Map.fetch!(@lane_collections, collection)

        for id <- Enum.sort(ids),
            {vf, at} = Map.fetch!(last, id),
            a = anchors.(entity, nil, at),
            a != nil do
          date = to_date(vf || at)
          recorded_at = to_date(at)
          code = {scheme, id}

          [
            Substrate.claim(
              source,
              :identity,
              %{ref: "#{collection}:#{id}", codes: [code], entity: lane},
              date,
              recorded_at
            ),
            Substrate.claim(source, :edge, %{from: code, relation: relation, to: a}, date, recorded_at)
          ]
        end
      end)
      |> List.flatten()

    all_codes =
      for %{snapshots: snaps} <- per_listing, {codes, _} <- snaps, c <- codes, into: MapSet.new(), do: c

    %{
      claims: stamp(identity ++ grouping ++ attribute ++ member_of ++ lane_entities),
      shared: MapSet.filter(all_codes, &ClaimMapping.shared?/1)
    }
  end

  @doc """
  Reconcile `claims` date by date, threading `ledger` forward — keys stay stable, and a code that
  bridges two established keys is GATED into a proposal, never auto-merged.

  `dates` defaults to every distinct claim date; the Product API passes only the NEW dates when
  appending live claims to an already-reconciled log (`claims` must still be the FULL claim set —
  clustering needs every live identity claim, not just the new ones).

  Returns `%{events: [dated identity events, order: nil], ledger: %IdentityLedger{}}`.
  """
  def fold_forward(claims, shared, ledger \\ IdentityLedger.new(), dates \\ nil, preferred \\ %{}) do
    dates =
      dates ||
        claims
        |> Enum.filter(&(&1.kind == :identity))
        |> Enum.map(& &1.recorded_at)
        |> Enum.uniq()
        |> Enum.sort(&(Bitemporal.compare(&1, &2) != :gt))

    # Incremental slot map instead of refilter + Substrate.current per date — O(N + D), see
    # Temporal.run/1. Orders are unique and monotone with recorded_at (stamp/1), so the last put
    # per slot is exactly Substrate.current's max-order winner. Assumes `dates` ascending, which
    # both the default and the append-new-dates caller satisfy.
    sorted = Enum.sort_by(claims, & &1.order)

    {events_rev, ledger, _current, _rest} =
      Enum.reduce(dates, {[], ledger, %{}, sorted}, fn d, {acc, prev, current, rest} ->
        {due, rest} = Enum.split_while(rest, &(Bitemporal.compare(&1.recorded_at, d) != :gt))
        current = Enum.reduce(due, current, &Map.put(&2, Substrate.slot(&1), &1))

        {events, _ledgers} =
          Lanes.reconcile(Map.values(current), shared, ledgers_from(prev), d, nil, preferred)

        {Enum.reverse(events, acc), Enum.reduce(events, prev, &IdentityLedger.evolve(&2, &1)), current, rest}
      end)

    %{events: Enum.reverse(events_rev), ledger: ledger}
  end

  @doc """
  Convenience: `build/1` + `fold_forward/2` + monotonic stamping — the finer analogue of
  `Temporal.run/1`. Returns `%{log, timeline, ledger, shared}`; `log` feeds the engine's read
  layer (and `Temporal.golden_as_of/3`) unchanged.
  """
  def run(envelopes) when is_list(envelopes) do
    %{claims: claims, shared: shared} = build(envelopes)
    %{events: events, ledger: ledger} = fold_forward(claims, shared)
    events = Rederivation.stamp(events, claims)

    %{log: claims ++ events, timeline: events, ledger: ledger, shared: shared}
  end

  # ── per-listing fold: one snapshot after every identity event ──────────────────────────────────

  defp listing_folds(envelopes) do
    for env <- envelopes,
        {{e, s}, evs} <-
          env.events
          |> Enum.filter(&(&1.kind == :identity))
          |> Enum.group_by(&{env.legacy_entity, &1.source})
          |> Enum.sort_by(&elem(&1, 0)) do
      evs = Enum.sort_by(evs, & &1.recorded_at)

      {snaps_rev, _raw} =
        Enum.reduce(evs, {[], %{}}, fn ev, {snaps, raw} ->
          raw = ClaimMapping.apply_identity(raw, ev)
          codes = ClaimMapping.engine_codes(raw)

          previous =
            case snaps do
              [{prev_codes, _date} | _] -> prev_codes
              [] -> MapSet.new()
            end

          cond do
            MapSet.size(codes) == 0 and MapSet.size(previous) == 0 -> {snaps, raw}
            match?([{^codes, _} | _], snaps) -> {snaps, raw}
            true -> {[{codes, to_date(ev.recorded_at)} | snaps], raw}
          end
        end)

      %{entity: e, source: s, snapshots: Enum.reverse(snaps_rev)}
    end
  end

  # Anchor lookup: (entity, source, epoch) -> the listing's primary code AS OF that moment,
  # falling back to the listing's FINAL primary when no snapshot precedes the event. A nil source
  # (genuinely unsourced event) falls back to the entity-level primary, mirroring ClaimMapping.
  defp anchor_index(per_listing) do
    by_listing =
      Map.new(per_listing, fn %{entity: e, source: s, snapshots: snaps} ->
        dated = Enum.map(snaps, fn {codes, date} -> {date, ClaimMapping.primary(Enum.sort(codes))} end)

        final =
          case List.last(dated) do
            {_, primary} -> primary
            nil -> nil
          end

        {{e, s}, %{dated: dated, final: final}}
      end)

    entity_final =
      per_listing
      |> Enum.group_by(& &1.entity)
      |> Map.new(fn {e, listings} ->
        union =
          for %{snapshots: snaps} <- listings,
              {codes, _} <- Enum.take(snaps, -1),
              c <- codes,
              into: MapSet.new(),
              do: c

        {e, ClaimMapping.primary(Enum.sort(union))}
      end)

    fn
      entity, nil, _epoch ->
        Map.get(entity_final, entity)

      entity, source, epoch ->
        case Map.get(by_listing, {entity, source}) do
          nil ->
            nil

          %{dated: dated, final: final} ->
            d = to_date(epoch)

            dated
            |> Enum.take_while(fn {date, _} -> Date.compare(date, d) != :gt end)
            |> List.last()
            |> case do
              {_, primary} -> primary
              nil -> final
            end
        end
    end
  end

  defp to_date(epoch), do: Bitemporal.effective_date(epoch)

  @doc false
  def ledgers_from(%IdentityLedger{} = ledger) do
    members_by_lane = Lanes.partition_members(ledger.members)

    Map.new(Lanes.lanes(), fn lane ->
      members = Map.fetch!(members_by_lane, lane)
      prefix = Lanes.prefix(lane)
      next = Map.get(Map.get(ledger, :next_by_prefix, %{}), prefix, next_key(members))

      {lane,
       %IdentityLedger{
         members: members,
         next: next,
         prefix: prefix,
         next_by_prefix: Map.get(ledger, :next_by_prefix, %{})
       }}
    end)
  end

  defp next_key(members) do
    members
    |> Map.keys()
    |> Enum.map(fn key -> key |> String.split("_") |> List.last() |> String.to_integer() end)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  # Chronological order stamp (later date ⇒ higher order), stable on emission index — the Date
  # analogue of ClaimMapping.stamp/1.
  defp stamp(claims) do
    claims
    |> Enum.with_index()
    |> Enum.sort_by(fn {c, i} -> {Date.to_erl(c.recorded_at), i} end)
    |> Enum.with_index()
    |> Enum.map(fn {{c, _i}, order} -> %{c | order: order} end)
  end
end
