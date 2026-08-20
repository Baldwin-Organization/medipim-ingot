defmodule GoldenRecord.History do
  alias GoldenRecord.{Events, Codes, Lanes, Substrate, Cluster, IdentityLedger, Catalog}

  @doc """
  Project what was known at `known_at` about the world on `effective_at`.

  Selection happens before identity reconciliation: future or bounded revisions cannot hide the
  prior applicable record, and a late correction changes only queries made after it was recorded.
  Effective intervals are half-open: `valid_from <= date < valid_to`.
  """
  def project_bitemporal(log, known_at, effective_at, priority) do
    state = state_bitemporal(log, known_at, effective_at)
    Catalog.project(state.members, state.claims, priority, state.overrides)
  end

  @doc false
  # ponytail: re-runs clustering + reconciliation at EVERY temporal boundary date —
  # O(boundaries × claims × cluster cost) per query (GH #57). Acceptable for point-in-time
  # audits on one entity's history; a hot bitemporal read path needs materialized per-boundary
  # state (the api/ read models are the intended home).
  def state_bitemporal(log, known_at, %Date{} = effective_at) do
    known = Enum.filter(log, &Bitemporal.known?(&1, known_at))

    # Two temporal semantics on purpose, with an expiry date (GH #59): the ingest fold does not
    # emit SourceRecordRevised yet (only SourceRecords does), so ingest-produced logs still take
    # legacy_state. DELETE the legacy branch once every producer emits source records.
    if Enum.any?(known, &match?(%Events.SourceRecordRevised{}, &1)) do
      source_record_state(known, effective_at)
    else
      legacy_state(known, effective_at)
    end
  end

  defp source_record_state(known, effective_at) do
    boundaries =
      known
      |> Enum.flat_map(fn event ->
        [Map.get(event, :valid_from), Map.get(event, :valid_to)]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn
        %Date{} = date -> date
        other -> Bitemporal.effective_date(other)
      end)
      |> Enum.filter(&(Date.compare(&1, effective_at) != :gt))
      |> Kernel.++([effective_at])
      |> Enum.uniq()
      |> Enum.sort(Date)

    # Boundary-invariant event lists, extracted once instead of refiltered per boundary.
    revisions = Enum.filter(known, &match?(%Events.SourceRecordRevised{}, &1))
    merges = Enum.filter(known, &match?(%Events.IdentitiesMerged{}, &1))
    bindings = Enum.filter(known, &match?(%Events.SourceRecordKeyBound{}, &1))

    ledger =
      Enum.reduce(boundaries, IdentityLedger.new(), fn boundary, ledger ->
        claims = claims_bitemporal_known(known, boundary)
        shared = shared(known, claims, boundary)

        # Per-lane clusters computed once per boundary, shared by preferred/ and the reconcile.
        lane_clusters =
          Map.new(Lanes.lanes(), fn lane ->
            identity = Lanes.identity_claims(claims, lane)
            evidence = Lanes.identity_evidence(claims, lane)
            {lane, Cluster.variants(identity ++ evidence, shared)}
          end)

        ledger = apply_merges(ledger, merges, boundary)

        reconcile_temporal(
          ledger,
          lane_clusters,
          preferred(revisions, merges, bindings, lane_clusters, boundary),
          shared,
          boundary
        )
      end)

    %{
      members: ledger.members,
      claims: claims_bitemporal_known(known, effective_at),
      overrides: overrides_from(Enum.filter(known, &Bitemporal.effective?(&1, effective_at)))
    }
  end

  defp legacy_state(known, effective_at) do
    applicable = Enum.filter(known, &Bitemporal.effective?(&1, effective_at))

    claims =
      applicable
      |> Enum.filter(&match?(%Events.ClaimAsserted{}, &1))
      |> Substrate.current()

    %{
      members: Enum.reduce(applicable, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1)).members,
      claims: claims,
      overrides: overrides_from(applicable)
    }
  end

  @doc false
  def claims_bitemporal(log, known_at, %Date{} = effective_at) do
    log
    |> Enum.filter(&Bitemporal.known?(&1, known_at))
    |> claims_bitemporal_known(effective_at)
  end

  defp claims_bitemporal_known(known, %Date{} = effective_at) do
    standalone =
      known
      |> Enum.filter(&match?(%Events.ClaimAsserted{}, &1))
      |> Enum.filter(&Bitemporal.effective?(&1, effective_at))
      |> Substrate.current()

    source =
      known
      |> selected_records(effective_at)
      |> Enum.flat_map(fn
        %Events.SourceRecordRevised{active: false} ->
          []

        revision ->
          Enum.map(revision.claims, fn claim ->
            %{
              claim
              | valid_from: revision.valid_from,
                valid_to: revision.valid_to,
                recorded_at: revision.recorded_at,
                order: revision.order
            }
          end)
      end)

    Substrate.current(standalone ++ source)
  end

  def project_as_of(log, date, priority), do: project_bitemporal(log, date, date, priority)

  def project_valid_as_of(log, valid_date, priority),
    do: project_bitemporal(log, DateTime.utc_now(), valid_date, priority)

  def now(log, priority), do: project_bitemporal(log, DateTime.utc_now(), Date.utc_today(), priority)

  defp selected_records(known, effective_at) do
    known
    |> Enum.filter(&match?(%Events.SourceRecordRevised{}, &1))
    |> Enum.filter(&Bitemporal.effective?(&1, effective_at))
    |> Enum.group_by(&{&1.source, &1.ref})
    |> Enum.map(fn {_record, revisions} ->
      Enum.max_by(revisions, &{Bitemporal.sort_key(&1.recorded_at), &1.order || -1})
    end)
  end

  # Near-duplicate of Lanes.reconcile/6 with ONE deliberate difference: an empty lane still runs
  # decide, which RETRACTS every key in it. Each boundary replays the complete claim set effective
  # at that date, so a lane with no clusters is evidence of absence — every claim expired — and
  # retraction is what keeps members consistent with the effective world (no zombie keys after
  # a validity window closes). Lanes.reconcile does the OPPOSITE (skip): it folds a possibly
  # partial append-only stream, where absence is merely no information. Do not converge the two —
  # see gr-huw and test/reconcile_empty_lane_test.exs. Consequence worth knowing: a product whose
  # claims lapse and later return mints a NEW key unless a SourceRecordKeyBound bridges the gap.
  defp reconcile_temporal(ledger, lane_clusters, preferred, shared, at) do
    {events, _ledgers} =
      Enum.flat_map_reduce(Lanes.lanes(), IdentityLedger.per_lane(ledger), fn lane, ledgers ->
        clusters = Map.fetch!(lane_clusters, lane)
        lane_preferred = Map.take(preferred, clusters)

        events =
          IdentityLedger.decide(
            ledgers[lane],
            {:reconcile, clusters, shared, lane_preferred, at}
          )

        next = Enum.reduce(events, ledgers[lane], &IdentityLedger.evolve(&2, &1))
        {events, Map.put(ledgers, lane, next)}
      end)

    Enum.reduce(events, ledger, &IdentityLedger.evolve(&2, &1))
  end

  defp preferred(revisions, merges, bindings, lane_clusters, effective_at) do
    records =
      revisions
      |> selected_records(effective_at)
      |> Enum.filter(& &1.active)
      |> Map.new(&{{&1.source, &1.ref}, &1})

    redirects =
      for merge <- merges,
          Bitemporal.effective?(merge, effective_at),
          from <- merge.from -- [merge.into],
          into: %{},
          do: {from, merge.into}

    clusters = Enum.flat_map(Lanes.lanes(), &Map.fetch!(lane_clusters, &1))

    bindings
    |> Enum.reduce(%{}, fn binding, acc ->
      with %Events.SourceRecordRevised{} = record <- Map.get(records, {binding.source, binding.ref}),
           identity when not is_nil(identity) <- Enum.find(record.claims, &(&1.kind == :identity)),
           codes = MapSet.new(identity.data.codes),
           cluster when not is_nil(cluster) <- Enum.find(clusters, &MapSet.subset?(codes, &1)) do
        key = follow_redirect(binding.key, redirects)
        Map.update(acc, cluster, [key], &[key | &1])
      else
        _ -> acc
      end
    end)
  end

  defp shared(known, claims, effective_at) do
    declared =
      for %Events.ConflictResolved{subject: {:code, code}, decision: :shared} = decision <- known,
          Bitemporal.effective?(decision, effective_at),
          into: MapSet.new(),
          do: code

    restricted =
      for claim <- claims,
          claim.kind == :identity,
          code <- claim.data.codes,
          Codes.shared?(code),
          into: MapSet.new(),
          do: code

    MapSet.union(declared, restricted)
  end

  defp apply_merges(ledger, merges, effective_at) do
    merges
    |> Enum.filter(&Bitemporal.effective?(&1, effective_at))
    |> Enum.sort_by(&(&1.order || -1))
    |> Enum.reduce(ledger, &IdentityLedger.evolve(&2, &1))
  end

  defp follow_redirect(key, redirects) do
    case Map.get(redirects, key) do
      nil -> key
      next -> follow_redirect(next, redirects)
    end
  end

  def lineage(log, key) do
    Enum.filter(log, fn
      %Events.IdentityMinted{key: k} -> k == key
      %Events.IdentityMembersChanged{key: k} -> k == key
      %Events.IdentitiesMerged{from: from, into: into} -> key in from or into == key
      %Events.IdentitySplit{key: k, into: into} -> k == key or Enum.any?(into, fn {nk, _} -> nk == key end)
      %Events.ConflictFlagged{subject: {:merge, keys}} -> key in keys
      %Events.ConflictFlagged{subject: {:attr, k, _}} -> k == key
      %Events.ConflictFlagged{subject: {:collision, k}} -> k == key
      %Events.MergeProposed{keys: keys} -> key in keys
      %Events.ConflictResolved{subject: {:merge, keys}} -> key in keys
      %Events.ConflictResolved{subject: {:attr, k, _}} -> k == key
      %Events.ConflictResolved{subject: {:collision, k}} -> k == key
      %Events.ConflictResolved{subject: {:split, k}} -> k == key
      %Events.LegacyIdAssigned{key: k} -> k == key
      _ -> false
    end)
  end

  defp overrides_from(events) do
    resolved = for %Events.ConflictResolved{} = e <- events, do: e

    attr =
      resolved
      |> Enum.filter(&match?(%Events.ConflictResolved{subject: {:attr, _, _}, decision: {:pick, _}}, &1))
      |> Enum.group_by(fn %Events.ConflictResolved{subject: {:attr, k, d}} -> {k, d} end)
      |> Map.new(fn {k, evs} -> {k, Enum.max_by(evs, &(&1.order || -1))} end)

    product =
      resolved
      |> Enum.filter(&match?(%Events.ConflictResolved{subject: {:collision, _}, decision: {:product, _}}, &1))
      |> Enum.group_by(fn %Events.ConflictResolved{subject: {:collision, k}} -> k end)
      |> Map.new(fn {k, evs} ->
        {k, evs |> Enum.max_by(&(&1.order || -1)) |> Map.fetch!(:decision) |> elem(1)}
      end)

    %{attr: attr, product: product}
  end
end
