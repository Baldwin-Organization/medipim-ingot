alias GoldenRecord.{Events, Substrate, Cluster, IdentityLedger, Catalog, History}

defmodule Api.State do
  @moduledoc """
  The materialized fold over the event log — everything reads need, maintained incrementally:
  the identity ledger, the CURRENT claim per slot (`Substrate.slot/1`), open conflict flags and
  resolved subjects, steward attribute/product overrides (mirroring `History.overrides_from/1`),
  pending merge endorsements (the first of the four eyes, keyed by sorted keys), and the
  legacy-ID assignments. Pure: `apply_event/2` is the only way state changes, so the
  snapshot is disposable by construction — re-folding the log MUST reproduce it (`Store.rebuild!`).
  """

  defstruct ledger: nil,
            current: %{},
            flags: [],
            resolved: MapSet.new(),
            overrides: %{attr: %{}, product: %{}},
            assigned: %{},
            shared: MapSet.new(),
            redirects: %{},
            proposals: %{},
            source_records: %{},
            source_record_revisions: %{},
            record_keys: %{},
            review_cases: %{},
            active_case_by_subject: %{},
            offset: 0

  def new, do: %__MODULE__{ledger: IdentityLedger.new()}

  def apply_event(%__MODULE__{} = s, %Events.ClaimAsserted{} = c),
    do: bump(%{s | current: Map.put(s.current, Substrate.slot(c), c)}, c)

  def apply_event(%__MODULE__{} = s, %Events.SourceRecordRevised{} = revision) do
    source = revision.source
    ref = revision.ref
    record = {source, ref}

    current =
      s.current
      |> Enum.reject(fn {slot, _claim} -> match?({^source, :record, ^ref, _}, slot) end)
      |> Map.new()

    current =
      if revision.active do
        Enum.reduce(revision.claims, current, fn claim, acc ->
          claim = %{claim | order: revision.order}
          Map.put(acc, Substrate.slot(claim), claim)
        end)
      else
        current
      end

    bump(
      %{
        s
        | current: current,
          source_records: Map.put(s.source_records, record, revision),
          source_record_revisions:
            Map.update(s.source_record_revisions, record, [revision], &(&1 ++ [revision]))
      },
      revision
    )
  end

  def apply_event(%__MODULE__{} = s, %Events.SourceRecordKeyBound{} = binding) do
    key = {binding.source, binding.ref, binding.lane}
    bump(%{s | record_keys: Map.put(s.record_keys, key, binding.key)}, binding)
  end

  def apply_event(%__MODULE__{} = s, %Events.LegacyIdAssigned{key: k, legacy_id: id} = e),
    do: bump(%{s | assigned: Map.put(s.assigned, k, id)}, e)

  def apply_event(%__MODULE__{} = s, %Events.ConflictFlagged{subject: subject} = f) do
    s = %{
      s
      | flags: Enum.reject(s.flags, &(&1.subject == subject)) ++ [f],
        resolved: MapSet.delete(s.resolved, subject)
    }

    s |> Api.ReviewCases.open_from_flag(f) |> bump(f)
  end

  # the first of the four eyes: remember WHO endorsed the merge (and why) until it resolves
  def apply_event(%__MODULE__{} = s, %Events.MergeProposed{keys: keys} = p),
    do: bump(%{s | proposals: Map.put(s.proposals, Enum.sort(keys), p)}, p)

  def apply_event(%__MODULE__{} = s, %Events.ConflictResolved{subject: subject} = r) do
    s =
      s
      |> Api.ReviewCases.close_subject(subject, r.decision)
      |> Map.put(:resolved, MapSet.put(s.resolved, subject))

    # a settled merge (approved or rejected) clears its pending endorsement
    s =
      case subject do
        {:merge, keys} -> %{s | proposals: Map.delete(s.proposals, Enum.sort(keys))}
        _ -> s
      end

    s =
      case {subject, r.decision} do
        {{:attr, k, f}, {:pick, _}} ->
          %{s | overrides: %{s.overrides | attr: Map.put(s.overrides.attr, {k, f}, r)}}

        {{:collision, k}, {:product, p}} ->
          %{s | overrides: %{s.overrides | product: Map.put(s.overrides.product, k, p)}}

        {{:code, code}, :shared} ->
          %{s | shared: MapSet.put(s.shared, code)}

        _ ->
          s
      end

    bump(s, r)
  end

  def apply_event(%__MODULE__{} = s, %Events.ReviewCaseOpened{} = opened),
    do: s |> Api.ReviewCases.apply_opened(opened) |> bump(opened)

  def apply_event(%__MODULE__{} = s, %Events.ReviewCaseEndorsed{} = endorsed),
    do: s |> Api.ReviewCases.apply_endorsed(endorsed) |> bump(endorsed)

  # a merge leaves a redirect for every absorbed key, so a legacy id assigned to one keeps
  # resolving — to the survivor — without ever scanning the log
  def apply_event(%__MODULE__{} = s, %Events.IdentitiesMerged{from: from, into: into} = e) do
    redirects = Enum.reduce(from -- [into], s.redirects, &Map.put(&2, &1, into))

    s = %{s | ledger: IdentityLedger.evolve(s.ledger, e), redirects: redirects}
    s = Api.ReviewCases.open_derived(s, {:split, into}, e.order)
    bump(s, e)
  end

  def apply_event(%__MODULE__{} = s, %Events.IdentityMembersChanged{} = event) do
    s = %{s | ledger: IdentityLedger.evolve(s.ledger, event)}

    s =
      if Enum.any?(s.redirects, fn {_from, into} -> follow(s, into) == event.key end),
        do: Api.ReviewCases.open_derived(s, {:split, event.key}, event.order),
        else: s

    bump(s, event)
  end

  # mint / members-changed / split — the ledger's own vocabulary
  def apply_event(%__MODULE__{} = s, identity_event),
    do: bump(%{s | ledger: IdentityLedger.evolve(s.ledger, identity_event)}, identity_event)

  def apply_all(%__MODULE__{} = s, events), do: Enum.reduce(events, s, &apply_event(&2, &1))

  @doc "The current claims, ordered — what `Catalog.project` and `Cluster.variants` fold over."
  def current_claims(%__MODULE__{current: current}),
    do:
      current
      |> Enum.sort_by(fn {slot, claim} -> {claim.order, slot} end)
      |> Enum.map(&elem(&1, 1))

  @doc "Project the golden catalog from this state (no log scan)."
  def golden(%__MODULE__{} = s, priority),
    do: Catalog.project(s.ledger.members, current_claims(s), priority, s.overrides)

  @doc "Open conflicts: flagged subjects without a steward decision, in flag order."
  def open_flags(%__MODULE__{} = s),
    do: Enum.reject(s.flags, &MapSet.member?(s.resolved, &1.subject))

  @doc "Follow merge redirects to the key that answers TODAY."
  def follow(%__MODULE__{redirects: redirects} = s, key) do
    case Map.get(redirects, key) do
      nil -> key
      next -> follow(s, next)
    end
  end

  defp bump(%__MODULE__{} = s, %{order: order}) when is_integer(order),
    do: %{s | offset: max(s.offset, order)}

  defp bump(s, _), do: s
end
