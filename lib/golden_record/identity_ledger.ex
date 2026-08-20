defmodule GoldenRecord.IdentityLedger do
  alias GoldenRecord.{Events, Codes, Lanes}

  @enforce_keys [:members, :next]
  defstruct [:members, :next, prefix: "SK", next_by_prefix: %{}]

  # The prefix is the lane qualifier (gr-2a8): :product ledgers keep the legacy "SK", other
  # lanes mint under their own prefix ("SUB_1", "DSC_1", …) — see Lanes.prefix/1.
  def new(prefix \\ "SK"),
    do: %__MODULE__{members: %{}, next: 1, prefix: prefix, next_by_prefix: %{prefix => 1}}

  def decide(state, {:reconcile, clusters, at}), do: decide(state, {:reconcile, clusters, MapSet.new(), at})

  def decide(state, {:reconcile, clusters, shared, at}),
    do: decide(state, {:reconcile, clusters, shared, %{}, at})

  def decide(
        %__MODULE__{members: members, next: next, prefix: prefix},
        {:reconcile, clusters, shared, preferred, at}
      ) do
    members
    |> reconcile(next, prefix, clusters, shared, preferred)
    |> then(&build_events(members, &1, at))
  end

  def evolve(%__MODULE__{} = s, %Events.IdentityMinted{key: k, codes: c}),
    do: advance(%{s | members: Map.put(s.members, k, c)}, k)

  def evolve(%__MODULE__{} = s, %Events.IdentityMembersChanged{key: k, codes: c}),
    do: advance(%{s | members: Map.put(s.members, k, c)}, k)

  def evolve(%__MODULE__{} = s, %Events.IdentitiesMerged{from: from, into: into}),
    do: %{s | members: Map.drop(s.members, from -- [into])}

  def evolve(%__MODULE__{} = s, %Events.IdentitySplit{key: k, kept_codes: kept, into: into}) do
    members = Enum.reduce(into, Map.put(s.members, k, kept), fn {nk, c}, m -> Map.put(m, nk, c) end)
    Enum.reduce(into, %{s | members: members}, fn {nk, _}, state -> advance(state, nk) end)
  end

  def evolve(%__MODULE__{} = s, %Events.IdentityRetracted{key: k}),
    do: %{s | members: Map.delete(s.members, k)}

  def evolve(%__MODULE__{} = s, %Events.ConflictFlagged{}), do: s
  def evolve(%__MODULE__{} = s, %Events.MergeProposed{}), do: s
  def evolve(%__MODULE__{} = s, %Events.ConflictResolved{}), do: s
  def evolve(%__MODULE__{} = s, %Events.ClaimAsserted{}), do: s
  def evolve(%__MODULE__{} = s, %Events.SourceRecordRevised{}), do: s
  def evolve(%__MODULE__{} = s, %Events.SourceRecordKeyBound{}), do: s
  def evolve(%__MODULE__{} = s, %Events.ReviewCaseOpened{}), do: s
  def evolve(%__MODULE__{} = s, %Events.ReviewCaseEndorsed{}), do: s
  def evolve(%__MODULE__{} = s, %Events.LegacyIdAssigned{}), do: s

  defp reconcile(old_members, next, prefix, clusters, shared, preferred) do
    original = old_members
    conflicts = cluster_conflicts(clusters, shared)
    non_bridging = MapSet.union(shared, MapSet.new(conflicts, &elem(&1, 0)))
    bare_index = bare_code_index(original, non_bridging)

    {assigns, members, next, minted, reactivated, proposals} =
      Enum.reduce(clusters, {[], old_members, next, [], [], []}, fn cluster,
                                                                    {assigns, m, n, minted, reactivated,
                                                                     proposals} ->
        candidates =
          (overlapping_keys(bare_index, cluster, non_bridging) ++ Map.get(preferred, cluster, []))
          |> Enum.uniq()
          |> Enum.sort()

        case candidates do
          [] ->
            key = "#{prefix}_#{n}"

            {[{cluster, key} | assigns], Map.put(m, key, cluster), n + 1, [key | minted], reactivated,
             proposals}

          [key] ->
            reactivated = if Map.has_key?(original, key), do: reactivated, else: [key | reactivated]

            {[{cluster, key} | assigns], Map.put(m, key, cluster), n, minted, reactivated, proposals}

          many ->
            # GATED: never auto-merge established keys — propose for steward review.
            {assigns, m, n, minted, reactivated, [{Enum.sort(many), cluster} | proposals]}
        end
      end)

    {members, _next, split} =
      assigns
      |> Enum.group_by(fn {_c, key} -> key end)
      |> Enum.reduce({members, next, []}, fn
        {_key, [_single]}, acc ->
          acc

        {key, multiple}, {m, n, split} ->
          prior = Map.get(original, key, MapSet.new())

          # Sorting first makes the tie-break total: Enum.max_by keeps the FIRST maximum, so
          # equal-ranked clusters resolve to the lowest code signature whatever order they arrived in.
          {keep_cluster, _} =
            multiple
            |> Enum.sort_by(fn {c, _} -> Enum.sort(c) end)
            |> Enum.max_by(fn {c, _} -> keeper_rank(c, prior) end)

          {into, m, n} =
            multiple
            |> Enum.map(&elem(&1, 0))
            |> List.delete(keep_cluster)
            |> Enum.reduce({[], m, n}, fn c, {ks, m, n} ->
              {[{"#{prefix}_#{n}", c} | ks], Map.put(m, "#{prefix}_#{n}", c), n + 1}
            end)

          {Map.put(m, key, keep_cluster), n, [{key, Enum.reverse(into)} | split]}
      end)

    # Reversed so that on a duplicate cluster the most recent assignment wins, exactly as the
    # Enum.find_value scan over the prepend-built list did. Then re-home clusters the split
    # pass moved onto freshly minted keys, so a held code spanning the split still surfaces
    # as a cross-key merge proposal below.
    assigns_by_cluster =
      split
      |> Enum.flat_map(fn {_key, into} -> into end)
      |> Enum.reduce(assigns |> Enum.reverse() |> Map.new(), fn {new_key, cluster}, acc ->
        Map.put(acc, cluster, new_key)
      end)

    held_proposals =
      conflicts
      |> Enum.flat_map(fn {_code, carriers} ->
        keys =
          carriers
          |> Enum.map(&Map.get(assigns_by_cluster, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.sort()

        if length(keys) > 1 do
          [{keys, Enum.reduce(carriers, &MapSet.union/2)}]
        else
          []
        end
      end)
      |> Enum.uniq_by(&elem(&1, 0))

    proposals = Enum.reverse(proposals) ++ held_proposals
    assigned_keys = MapSet.new(assigns, fn {_cluster, key} -> key end)
    proposed_keys = for {keys, _cluster} <- proposals, key <- keys, into: MapSet.new(), do: key
    touched = MapSet.union(assigned_keys, proposed_keys)
    retracted = for {key, _} <- original, not MapSet.member?(touched, key), do: key
    live = Map.drop(members, retracted)

    %{
      minted: Enum.reverse(minted),
      reactivated: Enum.reverse(reactivated),
      split: Enum.reverse(split),
      proposals: proposals,
      conflicts: conflicts,
      swaps: national_swaps(original, live),
      retracted: Enum.sort(retracted),
      members: live
    }
  end

  # An established key that LOSES a national code has changed what it denotes, even though it
  # survived reconciliation. Gaining one is an alias and stays quiet; losing one is the signature
  # of a barcode transfer or a mis-keyed upstream record, and a person should see it.
  defp national_swaps(original, live) do
    original
    |> Enum.flat_map(fn {key, prior} ->
      case Map.fetch(live, key) do
        :error ->
          []

        {:ok, now} ->
          lost = MapSet.difference(national_codes(prior), national_codes(now))
          if MapSet.size(lost) == 0, do: [], else: [{key, Enum.sort(lost), Enum.sort(now)}]
      end
    end)
    |> Enum.sort()
  end

  defp build_events(old_members, outcome, at) do
    mints =
      Enum.map(outcome.minted, &%Events.IdentityMinted{key: &1, codes: outcome.members[&1], recorded_at: at})

    reactivations =
      Enum.map(outcome.reactivated, fn key ->
        %Events.IdentityMembersChanged{key: key, codes: outcome.members[key], recorded_at: at}
      end)

    splits =
      Enum.map(outcome.split, fn {key, into} ->
        %Events.IdentitySplit{
          key: key,
          kept_codes: outcome.members[key],
          into: Enum.map(into, fn {k, _} -> {k, outcome.members[k]} end),
          recorded_at: at
        }
      end)

    proposals =
      Enum.map(outcome.proposals, fn {keys, cluster} ->
        %Events.ConflictFlagged{subject: {:merge, keys}, candidates: cluster, recorded_at: at}
      end)

    identity_conflicts =
      Enum.map(outcome.conflicts, fn {code, carriers} ->
        %Events.ConflictFlagged{
          subject: {:identity_conflict, code},
          candidates: Enum.map(carriers, &Enum.sort/1),
          recorded_at: at
        }
      end)

    identity_swaps =
      Enum.map(outcome.swaps, fn {key, lost, now} ->
        %Events.ConflictFlagged{subject: {:identity_swap, key}, candidates: [lost, now], recorded_at: at}
      end)

    retractions =
      Enum.map(outcome.retracted, fn key ->
        %Events.IdentityRetracted{key: key, codes: Map.get(old_members, key, MapSet.new()), recorded_at: at}
      end)

    mints ++
      reactivations ++
      splits ++
      proposals ++
      identity_conflicts ++ identity_swaps ++ retractions ++ keeps_changed(old_members, outcome, at)
  end

  defp keeps_changed(old_members, outcome, at) do
    skip =
      MapSet.new(Enum.flat_map(outcome.split, fn {key, into} -> [key | Enum.map(into, &elem(&1, 0))] end))

    for {key, old} <- old_members,
        not MapSet.member?(skip, key),
        Map.has_key?(outcome.members, key),
        outcome.members[key] != old,
        do: %Events.IdentityMembersChanged{key: key, codes: outcome.members[key], recorded_at: at}
  end

  # Inverted index (non-shared code -> [key]) built once per reconcile, so overlapping_keys is a
  # union of lookups instead of a full members scan per cluster.
  defp bare_code_index(members, shared) do
    for {key, codes} <- members, code <- MapSet.difference(codes, shared), reduce: %{} do
      acc -> Map.update(acc, code, [key], &[key | &1])
    end
  end

  defp overlapping_keys(bare_index, cluster, shared) do
    cluster
    |> MapSet.difference(shared)
    |> Enum.flat_map(&Map.get(bare_index, &1, []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp cluster_conflicts(clusters, shared) do
    clusters
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {cluster, index}, carriers ->
      Enum.reduce(cluster, carriers, fn code, acc ->
        if MapSet.member?(shared, code),
          do: acc,
          else: Map.update(acc, code, [{index, cluster}], &[{index, cluster} | &1])
      end)
    end)
    |> Enum.flat_map(fn {code, carriers} ->
      carriers = carriers |> Enum.uniq_by(&elem(&1, 0)) |> Enum.sort_by(&elem(&1, 0))
      if length(carriers) > 1, do: [{code, Enum.map(carriers, &elem(&1, 1))}], else: []
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc false
  # Which cluster KEEPS the key when one key's codes split across several clusters.
  #
  # The old rule was "whichever side holds a GTIN". That is backwards: a barcode is explicitly
  # reassignable — NHSBSA publishes a GTIN Transfer Tracking Log of codes moving between packs —
  # so a barcode following a product to a new pack would drag the surrogate key with it, silently
  # re-pointing every downstream reference. National codes are assigned once and never reissued,
  # so they, not the barcode, say which cluster CONTINUES what the key already meant.
  #
  # Ranked highest-first: national codes retained from the prior members, then other non-barcode
  # codes retained, then total overlap, then the cluster's own national weight (the CNK-outranks-
  # GTIN rule LegacyXref spells out) for a split with no prior overlap at all.
  def keeper_rank(cluster, prior) do
    shared = MapSet.intersection(cluster, prior)

    {grade_count(shared, :national), grade_count(shared, :none), MapSet.size(shared),
     grade_count(cluster, :national)}
  end

  defp grade_count(codes, grade),
    do: Enum.count(codes, fn {scheme, _} -> Codes.bridge_grade(scheme) == grade end)

  defp national_codes(codes),
    do: codes |> Enum.filter(fn {scheme, _} -> Codes.national_grade?(scheme) end) |> MapSet.new()

  # Works for any lane prefix ("SK_7", "SUB_3", "DSC_12" — the trailing integer is the counter).
  defp key_num(key), do: key |> String.split("_") |> List.last() |> String.to_integer()

  defp key_prefix(key), do: key |> String.split("_") |> Enum.drop(-1) |> Enum.join("_")

  # BOTH counters are load-bearing, not legacy duplication (GH #59): the scalar `next` is the
  # cross-prefix max that decide/split mint from on a COMBINED ledger (all lanes folded into
  # one — switching them to next_by_prefix[prefix] would renumber minted keys and break parity
  # pins); `next_by_prefix` is what per_lane/1 seeds each lane's own ledger from.
  defp advance(%__MODULE__{} = s, key) do
    next = key_num(key) + 1
    prefix = key_prefix(key)

    %{
      s
      | next: max(s.next, next),
        next_by_prefix: Map.update(s.next_by_prefix, prefix, next, &max(&1, next))
    }
  end

  @doc """
  Split one combined ledger into per-lane ledgers, each minting under its lane prefix — the
  engine-side home of what the temporal ingest fold needs at every boundary (GH #56).
  """
  def per_lane(%__MODULE__{} = ledger) do
    members_by_lane = Lanes.partition_members(ledger.members)

    Map.new(Lanes.lanes(), fn lane ->
      members = Map.fetch!(members_by_lane, lane)
      prefix = Lanes.prefix(lane)
      next = Map.get(ledger.next_by_prefix, prefix, next_key(members))

      {lane,
       %__MODULE__{
         members: members,
         next: next,
         prefix: prefix,
         next_by_prefix: ledger.next_by_prefix
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
end
