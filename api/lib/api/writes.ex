alias GoldenRecord.{Events, Codes, Lanes, Relations, Substrate, Cluster, Stewardship}

defmodule Api.Writes do
  @moduledoc """
  The Product API's two write paths, sharing ONE reconcile pipeline:

  * `backfill/1` — contract-C envelopes, folded finer-grained (`FinerClaims`), idempotent per
    envelope via a content fingerprint in `backfill_seen` (same transaction as the append).
  * `claims/1` — live canonical claims (`docs/CLAIMS_CONTRACT.md`), validated whole and built
    by the generic canonical→engine stage (`CanonicalClaims.to_engine/2`), idempotent per claim.

  Live-claim idempotency — the deterministic claim identity: a claim IS its content,
  `{source, kind, data, valid_from}` — the contract's idempotency fields (source, scheme+code,
  field, value, valid_from); `data` carries codes already canonicalized by `Substrate.claim/5`,
  so equivalent spellings (`"ean:…"` vs its GTIN-14) share one identity. `recorded_at` (the
  server clock) and `order` are deliberately excluded, so resubmitting the same claim on a later
  day is still the same claim — but ONLY when `valid_from` is explicit; with `valid_from` omitted
  it defaults to that day's `recorded_at` (`CanonicalClaims.to_engine/2`), so an otherwise
  identical resubmission on a later day is a DIFFERENT identity. Inside the writer transaction a claim whose slot
  (`Substrate.slot/1`) currently holds identical content is SKIPPED — resubmitting a batch
  appends nothing and churns nothing (mirrors the backfill no-op branch), while a changed
  payload still updates its slot (last-wins per the contract).

  Pipeline (inside the store's writer transaction): pre-stamp the new claims with the offsets
  they WILL get → fold-forward reconcile over the FULL current claim set, threading the live
  ledger over only the NEW dates (keys stay stable; a bridge between established keys is GATED,
  never auto-merged) → assign legacy IDs to any key that lacks one → append claims + identity
  events + assignments as one atomic batch. The response surfaces what identity DID: minted /
  changed keys and — most importantly — any flagged merge proposals.
  """

  def backfill(envelope_maps) when is_list(envelope_maps) do
    with {:ok, envelopes} <- decode_envelopes(envelope_maps) do
      fingerprinted = Enum.map(envelopes, fn env -> {env, fingerprint(env)} end)

      Api.Store.append(fn state, conn ->
        fresh = Enum.reject(fingerprinted, fn {env, fp} -> seen?(conn, env.legacy_entity, fp) end)

        case fresh do
          [] ->
            {:ok, [], summary(0, length(envelopes), [], [])}

          fresh ->
            %{claims: new_claims, shared: envelope_shared} =
              FinerClaims.build(Enum.map(fresh, &elem(&1, 0)))

            {events, identity_events} = pipeline(state, new_claims, envelope_shared)
            Enum.each(fresh, fn {env, fp} -> mark_seen(conn, env.legacy_entity, fp) end)

            {:ok, events,
             summary(
               length(fresh),
               length(envelopes) - length(fresh),
               new_claims,
               identity_events
             )}
        end
      end)
    else
      {:error, errors} -> {:error, {422, %{errors: errors}}}
    end
  end

  def backfill(_),
    do: {:error, {422, %{errors: [%{index: nil, error: "envelopes must be a list"}]}}}

  def claims(claim_maps, idempotency_key \\ nil) do
    case build_live_claims(claim_maps) do
      {:ok, new_claims, warnings} ->
        fp = fingerprint_term(claim_maps)

        Api.Store.append(fn state, conn ->
          with :fresh <- live_batch(conn, idempotency_key, fp) do
            {fresh, events, identity_events} = resolve(state, new_claims)

            response =
              summary(
                length(fresh),
                length(new_claims) - length(fresh),
                fresh,
                identity_events,
                warnings
              )

            remember_live_batch(conn, idempotency_key, fp, response)
            {:ok, events, response}
          end
        end)

      {:error, errors} ->
        {:error,
         {422,
          %{
            errors:
              Enum.map(errors, fn %{index: index, error: error} ->
                %{index: index, error: error}
              end)
          }}}
    end
  end

  @doc """
  Atomically revise one upstream record identified by `{source, ref, revision}`.

  Unlike `/claims`, this owns a complete source record: replace removes omissions, patch keeps
  omissions, withdraw removes every contribution, and reactivate restores the durable key.
  """
  def source_record(source, ref, revision, params) when is_map(params) do
    today = Date.utc_today()

    with {:ok, operation} <- source_operation(params["operation"]),
         {:ok, valid_from} <- source_valid_from(params["valid_from"], today),
         {:ok, valid_to} <- source_valid_to(params["valid_to"]),
         {:ok, claims, warnings} <-
           source_claims(source, ref, revision, params, operation, valid_from),
         {:ok, remove_slots} <- remove_slots(params["remove"] || []) do
      Api.Store.append(fn state, _conn ->
        recorded_at = DateTime.utc_now()
        current = Map.get(state.source_records, {source, ref})

        historical =
          state.source_record_revisions
          |> Map.get({source, ref}, [])
          |> Enum.find(&(&1.revision == revision))

        case SourceRecords.revise(historical || current,
               source: source,
               ref: ref,
               revision: revision,
               base_revision: params["base_revision"],
               operation: operation,
               claims: claims,
               remove_slots: remove_slots,
               valid_from: valid_from,
               valid_to: valid_to,
               recorded_at: recorded_at
             ) do
          {:replay, record} ->
            {:ok, [], source_record_response(state, record, [], warnings, true)}

          {:ok, record} ->
            {events, identity_events, would_state} = source_record_pipeline(state, record)

            {:ok, events,
             source_record_response(would_state, record, identity_events, warnings, false)}

          {:error, {status, error}} ->
            {:error, {status, %{error: error}}}
        end
      end)
    else
      {:error, {status, error}} -> {:error, {status, %{error: error}}}
      {:error, errors} when is_list(errors) -> {:error, {422, %{errors: errors}}}
    end
  end

  def source_record(_source, _ref, _revision, _params),
    do: {:error, {422, %{error: "body must be an object"}}}

  @doc """
  The claims write UNCOMMITTED (gr-rlq, `POST /v1/dry-run`): the exact `claims/1` path —
  validate, dedupe per slot, fold-forward reconcile, legacy-id assignment — run against `state`
  without ever touching the store. Returns `{:ok, outcome}` where `outcome.summary` is precisely
  what `claims/1` would respond for the same batch, `outcome.identity_events` are the raw engine
  events the fold produced, `outcome.events` are the full stamped events the commit would append
  (offsets exactly what `Store.insert_and_fold` will re-assign from the same `state` — so a
  caller holding the writer lock may append them verbatim, which is how `Api.Cutover` commits),
  and `outcome.would_state` is the `Api.State` the commit WOULD have left behind — or
  `{:error, errors}` with the per-index findings `claims/1` would 422 with.

  `compact: true` (gr-w4l, the cutover flavor) first keeps only the LAST claim per slot: a
  migration batch is the source's CURRENT truth, not a replay of its history, and without
  compaction a batch carrying several values for one slot can never converge — every re-run
  re-appends the non-final values and the last append wins, flipping the answer back.
  `outcome.compacted` counts the claims dropped that way (0 without the option).
  """
  def simulate(state, claim_maps, opts \\ []) do
    case build_live_claims(claim_maps) do
      {:ok, new_claims, warnings} ->
        batch = if opts[:compact], do: compact(new_claims), else: new_claims

        {fresh, events, identity_events} = resolve(state, batch)

        stamped =
          events
          |> Enum.with_index(state.offset + 1)
          |> Enum.map(fn {e, i} -> %{e | order: i} end)

        {:ok,
         %{
           summary:
             summary(
               length(fresh),
               length(batch) - length(fresh),
               fresh,
               identity_events,
               warnings
             ),
           compacted: length(new_claims) - length(batch),
           identity_events: identity_events,
           events: stamped,
           would_state: Api.State.apply_all(state, stamped)
         }}

      {:error, errors} ->
        {:error,
         Enum.map(errors, fn %{index: index, error: error} -> %{index: index, error: error} end)}
    end
  end

  defp build_live_claims(claim_maps) do
    case ClaimsValidator.validate(claim_maps) do
      {:ok, warnings} ->
        {:ok, CanonicalClaims.to_engine!(claim_maps, recorded_at: DateTime.utc_now()), warnings}

      {:error, errors} ->
        {:error, errors}
    end
  end

  defp source_record_pipeline(state, record) do
    preview = Api.State.apply_event(state, %{record | order: state.offset + 1})
    old_live = Api.State.current_claims(state)
    live = Api.State.current_claims(preview)
    reconcile_live = withdrawal_marker(record, live)
    shared = shared_of(reconcile_live) |> MapSet.union(state.shared)
    preferred = preferred_clusters(preview, reconcile_live, shared)

    %{events: raw_identity_events, ledger: ledger} =
      FinerClaims.fold_forward(
        reconcile_live,
        shared,
        state.ledger,
        [record.valid_from],
        preferred
      )

    identity_events = Enum.map(raw_identity_events, &temporalize(&1, record))

    withdrawal_flags =
      Stewardship.detect_withdrawals(old_live, live, ledger.members, record.recorded_at)
      |> Enum.map(&temporalize(&1, record))

    attribute_flags =
      Stewardship.detect(ledger.members, live, Api.Priority.current(), record.recorded_at)
      |> Enum.map(&temporalize(&1, record))
      |> changed_review_flags(state, [record] ++ identity_events ++ withdrawal_flags)

    assignments =
      LegacyIds.decide(product_members(ledger.members), live, state.assigned, record.recorded_at)

    binding =
      case Map.get(state.record_keys, {record.source, record.ref, source_lane(record)}) do
        nil -> bind_record(record, ledger)
        _key -> []
      end

    events =
      [record] ++ identity_events ++ withdrawal_flags ++ attribute_flags ++ assignments ++ binding

    stamped =
      events
      |> Enum.with_index(state.offset + 1)
      |> Enum.map(fn {event, order} -> %{event | order: order} end)

    {events, identity_events, Api.State.apply_all(state, stamped)}
  end

  defp withdrawal_marker(%Events.SourceRecordRevised{active: true}, live), do: live

  defp withdrawal_marker(record, live) do
    identity = Enum.find(record.claims, &(&1.kind == :identity))

    marker = %{
      identity
      | data: %{identity.data | codes: []},
        recorded_at: record.valid_from,
        order: nil
    }

    live ++ [marker]
  end

  defp preferred_clusters(state, live, shared) do
    identity_by_record =
      live
      |> Enum.filter(&(&1.kind == :identity and not is_nil(&1.record_ref)))
      |> Map.new(&{{&1.source, &1.record_ref}, MapSet.new(&1.data.codes)})

    clusters =
      for lane <- Lanes.lanes(),
          claims = Lanes.identity_claims(live, lane),
          claims != [],
          cluster <- Cluster.variants(claims ++ Lanes.identity_evidence(live, lane), shared),
          do: cluster

    Enum.reduce(state.record_keys, %{}, fn {{source, ref, _lane}, key}, acc ->
      case Map.get(identity_by_record, {source, ref}) do
        nil ->
          acc

        codes ->
          case Enum.find(clusters, &MapSet.subset?(codes, &1)) do
            nil ->
              acc

            cluster ->
              Map.update(
                acc,
                cluster,
                [Api.State.follow(state, key)],
                &[Api.State.follow(state, key) | &1]
              )
          end
      end
    end)
  end

  defp bind_record(%Events.SourceRecordRevised{active: false}, _ledger), do: []

  defp bind_record(record, ledger) do
    identity = Enum.find(record.claims, &(&1.kind == :identity))
    {:ok, lane} = Lanes.of_claim(identity)
    codes = MapSet.new(identity.data.codes)

    case Enum.find(ledger.members, fn {_key, members} -> MapSet.subset?(codes, members) end) do
      {key, _} ->
        [
          %Events.SourceRecordKeyBound{
            source: record.source,
            ref: record.ref,
            lane: lane,
            key: key,
            valid_from: record.valid_from,
            valid_to: record.valid_to,
            recorded_at: record.recorded_at
          }
        ]

      nil ->
        []
    end
  end

  defp source_lane(%Events.SourceRecordRevised{claims: claims}) do
    claims |> Enum.find(&(&1.kind == :identity)) |> Lanes.of_claim() |> elem(1)
  end

  defp source_record_response(state, record, identity_events, warnings, replayed) do
    lane = source_lane(record)
    key = Map.get(state.record_keys, {record.source, record.ref, lane})
    key = if key, do: Api.State.follow(state, key)

    %{
      source: record.source,
      ref: record.ref,
      revision: record.revision,
      operation: Atom.to_string(record.operation),
      status: if(record.active, do: "active", else: "withdrawn"),
      recorded_at: DateTime.to_iso8601(Bitemporal.to_datetime(record.recorded_at)),
      valid_from: Date.to_iso8601(record.valid_from),
      valid_to: record.valid_to && Date.to_iso8601(record.valid_to),
      key: key,
      legacy_id: key && Map.get(state.assigned, key),
      replayed: replayed,
      warnings: warnings,
      events: Enum.map(identity_events, &event_view/1)
    }
  end

  defp source_operation(operation)
       when operation in ["replace", "patch", "withdraw", "reactivate"],
       do: {:ok, String.to_existing_atom(operation)}

  defp source_operation(operation),
    do:
      {:error,
       {422,
        "operation must be replace, patch, withdraw, or reactivate; got #{inspect(operation)}"}}

  defp source_valid_from(nil, recorded_at), do: {:ok, recorded_at}

  defp source_valid_from(raw, _recorded_at) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, {422, "valid_from must be an ISO date"}}
    end
  end

  defp source_valid_from(_raw, _recorded_at),
    do: {:error, {422, "valid_from must be an ISO date"}}

  defp source_valid_to(nil), do: {:ok, nil}

  defp source_valid_to(raw) when is_binary(raw) do
    case Date.from_iso8601(raw) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, {422, "valid_to must be an ISO date or null"}}
    end
  end

  defp source_valid_to(_raw), do: {:error, {422, "valid_to must be an ISO date or null"}}

  defp source_claims(source, ref, revision, params, operation, valid_from) do
    raw =
      case operation do
        :patch -> params["upsert"] || params["claims"] || []
        :withdraw -> params["claims"] || []
        _ -> params["claims"] || []
      end

    if is_list(raw) do
      maps =
        Enum.map(raw, fn claim ->
          claim
          |> Map.put("source", source)
          |> Map.put("valid_from", Date.to_iso8601(valid_from))
          |> then(fn
            %{"kind" => "identity"} = identity -> Map.put(identity, "ref", ref)
            other -> other
          end)
        end)

      case ClaimsValidator.validate(maps) do
        {:ok, warnings} ->
          claims =
            maps
            |> CanonicalClaims.to_engine!(recorded_at: valid_from)
            |> Enum.map(&%{&1 | record_ref: ref, record_revision: revision})

          {:ok, claims, warnings}

        {:error, errors} ->
          {:error, errors}
      end
    else
      {:error, {422, "claims/upsert must be a list"}}
    end
  end

  defp remove_slots(remove) when is_list(remove) do
    remove
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {selector, index}, {:ok, slots} ->
      case remove_slot(selector) do
        {:ok, slot} -> {:cont, {:ok, [slot | slots]}}
        {:error, error} -> {:halt, {:error, {422, "remove[#{index}]: #{error}"}}}
      end
    end)
    |> case do
      {:ok, slots} -> {:ok, Enum.reverse(slots)}
      error -> error
    end
  end

  defp remove_slots(_), do: {:error, {422, "remove must be a list"}}

  defp remove_slot(%{"kind" => "identity"}), do: {:ok, :identity}

  defp remove_slot(%{"kind" => "grouping", "code" => code}),
    do:
      with(
        {:ok, code} <- CanonicalClaims.parse_code(code),
        do: {:ok, {:grouping, Codes.canonicalize(code)}}
      )

  defp remove_slot(%{"kind" => "attribute", "code" => code, "field" => field}),
    do:
      with(
        {:ok, code} <- CanonicalClaims.parse_code(code),
        do: {:ok, {:attr, Codes.canonicalize(code), field}}
      )

  defp remove_slot(%{"kind" => "media", "asset" => asset, "target" => target}),
    do:
      with(
        {:ok, target} <- CanonicalClaims.parse_code(target),
        do: {:ok, {:media, {:dam, asset}, Codes.canonicalize(target)}}
      )

  defp remove_slot(%{"kind" => "edge", "from" => from, "relation" => relation, "to" => to}) do
    with {:ok, from} <- CanonicalClaims.parse_code(from),
         {:ok, relation} <- Relations.parse(relation),
         {:ok, to} <- CanonicalClaims.parse_code(to) do
      {:ok, {:edge, Codes.canonicalize(from), relation, Codes.canonicalize(to)}}
    else
      _ -> {:error, "invalid edge selector"}
    end
  end

  defp remove_slot(_), do: {:error, "unsupported or incomplete selector"}

  defp temporalize(event, record) do
    %{
      event
      | valid_from: record.valid_from,
        valid_to: record.valid_to,
        recorded_at: record.recorded_at
    }
  end

  # Last claim per slot wins, batch order preserved — the cutover's compaction (see simulate/3).
  defp compact(claims),
    do: claims |> Enum.reverse() |> Enum.uniq_by(&Substrate.slot/1) |> Enum.reverse()

  # The shared resolve body for `claims/1` and `simulate/3` (gr-rlq/gr-dfp): winnow the batch
  # against the threaded slot view, then run the reconcile pipeline over what's left (or nothing).
  defp resolve(state, batch) do
    fresh = winnow(state, batch)

    {events, identity_events} =
      case fresh do
        [] -> {[], []}
        fresh -> pipeline(state, fresh, MapSet.new())
      end

    {fresh, events, identity_events}
  end

  # Drop the no-ops, keep the real assertions — checking each entry against the slot view it
  # BUILDS UP (gr-cih), not the stale transaction-start state. An entry whose slot already holds
  # identical content (in-batch OR pre-batch) is a pure no-op under last-wins and is dropped;
  # changed content in the same slot is kept. Threading the view is what makes a batch that
  # asserts one slot twice settle last-wins, rather than mis-skipping a later entry that happens
  # to equal the pre-batch value. Exact-duplicate entries collapse first via `claim_identity`.
  defp winnow(state, batch) do
    {kept, _view} =
      batch
      |> Enum.uniq_by(&claim_identity/1)
      |> Enum.reduce({[], state.current}, fn claim, {kept, view} ->
        slot = Substrate.slot(claim)
        current = Map.get(view, slot)

        if current && claim_identity(current) == claim_identity(claim) do
          {kept, view}
        else
          {[claim | kept], Map.put(view, slot, claim)}
        end
      end)

    Enum.reverse(kept)
  end

  # ── deterministic claim identity (idempotent resubmission — see the moduledoc) ─
  defp claim_identity(c), do: {c.source, c.kind, c.data, c.valid_from}

  defp product_members(members) do
    members
    |> Enum.filter(fn {key, _codes} -> Lanes.lane_of_key(key) == :product end)
    |> Map.new()
  end

  # ── the shared reconcile pipeline ───────────────────────────────────────────
  defp pipeline(state, new_claims, extra_shared) do
    prestamped =
      new_claims
      |> Enum.with_index(state.offset + 1)
      |> Enum.map(fn {c, i} -> %{c | order: i} end)

    all = Api.State.current_claims(state) ++ prestamped
    shared = shared_of(all) |> MapSet.union(extra_shared) |> MapSet.union(state.shared)

    new_dates =
      prestamped
      |> Enum.filter(&(&1.kind == :identity))
      |> Enum.map(& &1.recorded_at)
      |> Enum.uniq()
      |> Enum.sort(&(Bitemporal.compare(&1, &2) != :gt))

    %{events: identity_events, ledger: ledger} =
      FinerClaims.fold_forward(all, shared, state.ledger, new_dates)

    at = List.last(new_dates) || Date.utc_today()
    assignments = LegacyIds.decide(product_members(ledger.members), all, state.assigned, at)

    attribute_flags =
      Stewardship.detect(ledger.members, all, Api.Priority.current(), at)
      |> changed_review_flags(state, new_claims ++ identity_events)

    # the store stamps real offsets in THIS order — the claims land exactly on their pre-stamps
    {new_claims ++ identity_events ++ attribute_flags ++ assignments, identity_events}
  end

  defp shared_of(claims) do
    for c <- claims,
        c.kind == :identity,
        code <- c.data.codes,
        ClaimMapping.shared?(code),
        into: MapSet.new(),
        do: code
  end

  defp changed_review_flags(flags, state, preceding_events) do
    projected =
      preceding_events
      |> Enum.with_index(state.offset + 1)
      |> Enum.map(fn {event, order} -> %{event | order: order} end)
      |> then(&Api.State.apply_all(state, &1))

    Enum.reject(flags, fn flag ->
      with {:ok, evidence} <- Api.ReviewCases.evidence(projected, flag.subject),
           latest when not is_nil(latest) <- latest_review(state, flag.subject) do
        latest.evidence_digest == Api.ReviewCases.digest(evidence)
      else
        _ -> false
      end
    end)
  end

  defp latest_review(state, subject) do
    state.review_cases
    |> Map.values()
    |> Enum.filter(&(&1.subject == subject))
    |> Enum.max_by(& &1.evidence_offset, fn -> nil end)
  end

  # ── envelope decoding + idempotency ─────────────────────────────────────────
  defp decode_envelopes(maps) do
    maps
    |> Enum.with_index()
    |> Enum.map(fn {map, index} ->
      case HistoryEnvelope.from_map(map) do
        {:ok, env} -> {:ok, env}
        {:error, reason} -> {:error, %{index: index, error: format_reason(reason)}}
      end
    end)
    |> Enum.split_with(&match?({:ok, _}, &1))
    |> case do
      {oks, []} -> {:ok, Enum.map(oks, fn {:ok, env} -> env end)}
      {_, errors} -> {:error, Enum.map(errors, fn {:error, e} -> e end)}
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  # Content fingerprint for replay-is-a-no-op. Stable for identical content within a BEAM
  # version; a changed fingerprint after an upgrade only costs a harmless re-append (the claims
  # dedupe per slot in the fold).
  defp fingerprint(env), do: :crypto.hash(:sha256, :erlang.term_to_binary(env)) |> Base.encode16()

  defp fingerprint_term(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16()

  defp live_batch(_conn, nil, _fp), do: :fresh

  defp live_batch(conn, key, fp) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        "SELECT fingerprint, response FROM live_batches WHERE idempotency_key = $1",
        [key]
      )

    case rows do
      [] ->
        :fresh

      [[^fp, response]] ->
        {:ok, [], Api.Codec.decode!(response)}

      [[_other, _response]] ->
        {:error, {409, %{error: "idempotency key was already used with different claims"}}}
    end
  end

  defp remember_live_batch(_conn, nil, _fp, _response), do: :ok

  defp remember_live_batch(conn, key, fp, response) do
    Postgrex.query!(
      conn,
      "INSERT INTO live_batches (idempotency_key, fingerprint, response) VALUES ($1, $2, $3)",
      [key, fp, Api.Codec.encode!(response)]
    )
  end

  defp seen?(conn, entity, fp) do
    %{rows: rows} =
      Postgrex.query!(
        conn,
        "SELECT 1 FROM backfill_seen WHERE legacy_entity = $1 AND fingerprint = $2",
        [entity, fp]
      )

    rows != []
  end

  defp mark_seen(conn, entity, fp),
    do:
      Postgrex.query!(
        conn,
        "INSERT INTO backfill_seen (legacy_entity, fingerprint) VALUES ($1, $2)",
        [
          entity,
          fp
        ]
      )

  # ── the response: what identity DID ─────────────────────────────────────────
  defp summary(accepted, skipped, new_claims, identity_events, warnings \\ []) do
    %{
      accepted: accepted,
      skipped: skipped,
      claims: length(new_claims),
      warnings: warnings,
      events: Enum.map(identity_events, &event_view/1),
      # the guard RE-proposes at every date after a bridge appears — one entry per subject
      flagged:
        for(
          %Events.ConflictFlagged{subject: {:merge, keys}} <- identity_events,
          do: %{type: "merge_proposal", keys: keys}
        )
        |> Enum.uniq()
    }
  end

  defp event_view(%Events.IdentityMinted{key: k, recorded_at: at}),
    do: %{type: "minted", key: k, date: time_iso(at)}

  defp event_view(%Events.IdentityMembersChanged{key: k, recorded_at: at}),
    do: %{type: "members_changed", key: k, date: time_iso(at)}

  defp event_view(%Events.IdentitiesMerged{from: from, into: into, recorded_at: at}),
    do: %{type: "merged", from: from, into: into, date: time_iso(at)}

  defp event_view(%Events.IdentitySplit{key: k, into: into, recorded_at: at}),
    do: %{type: "split", key: k, into: Enum.map(into, &elem(&1, 0)), date: time_iso(at)}

  defp event_view(%Events.IdentityRetracted{key: k, recorded_at: at}),
    do: %{type: "retracted", key: k, date: time_iso(at)}

  defp event_view(%Events.ConflictFlagged{subject: {:merge, keys}, recorded_at: at}),
    do: %{type: "merge_proposal", keys: keys, date: time_iso(at)}

  defp event_view(%Events.ConflictFlagged{subject: subject, recorded_at: at}),
    do: %{type: "flag", subject: inspect(subject), date: time_iso(at)}

  defp time_iso(%Date{} = date), do: Date.to_iso8601(date)
  defp time_iso(%DateTime{} = datetime), do: datetime |> DateTime.to_date() |> Date.to_iso8601()
end
