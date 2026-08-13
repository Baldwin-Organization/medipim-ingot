# lib/ingest/legacy_ids.ex — legacy-ID continuity for the medipim takeover (gr-twa).
#
# BACKWARDS COMPATIBILITY (docs/plans/2026-06-10-medipim-product-api-design.md): every golden
# record answers to a legacy medipim product ID, forever — medipim and everything downstream keeps
# speaking medipim IDs while the engine owns identity underneath.
#
#   * BACKFILLED keys inherit the legacy entity their evidence came from: the ingest synthesizes a
#     grouping claim per (listing, code) with `product: legacy_entity`, so a key's legacy ID is the
#     entity its member codes vote for (most grouping claims wins; ties break to the LOWEST id —
#     deterministic, and the older entity is the one external references most likely use).
#   * NEW keys (post-backfill products, or keys carved out by a steward split) get a freshly
#     ALLOCATED id, above every id ever seen — so it can never collide with a real medipim entity.
#
# Assignment is an EVENT (`Events.LegacyIdAssigned`) in the log — auditable, replayable — never a
# side table. Resolution follows identity: a merged key's legacy id keeps resolving, to the
# SURVIVOR (the absorbed id becomes an alias); a split key keeps its id on the KEPT key and the
# carved-out keys allocate fresh ones on the next `decide/4`.

defmodule LegacyIds do
  @moduledoc """
  Legacy medipim IDs as first-class, event-sourced continuity: `decide/4` proposes
  `Events.LegacyIdAssigned` for live keys that lack one (inherit from grouping evidence, else
  allocate above the max), `fold/1` projects the current `key => legacy_id` map, and `resolve/2`
  answers a legacy id with the key it lands on TODAY — following merges to the survivor.
  """

  @doc "Latest `%{key => legacy_id}` assignment per key, folded from the log."
  def fold(log) do
    for %Events.LegacyIdAssigned{key: k, legacy_id: id} <- log, into: %{}, do: {k, id}
  end

  @doc """
  Propose assignments for every key in `members` that has none. `claims` provides the grouping
  evidence (backfilled keys vote by their member codes); `assigned` is `fold/1` of the log so far.
  Allocation for evidence-less keys starts above every id ever seen — assigned or voted.
  Deterministic: keys are processed in sorted order. Idempotent: fully-assigned members ⇒ `[]`.
  """
  def decide(members, claims, assigned, at) do
    votes = grouping_votes(claims)

    floor =
      (Map.values(assigned) ++ Enum.flat_map(votes, fn {_code, tally} -> Map.keys(tally) end))
      |> Enum.max(fn -> 0 end)

    {events, _next} =
      members
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reject(fn {key, _codes} -> Map.has_key?(assigned, key) end)
      |> Enum.map_reduce(floor + 1, fn {key, codes}, next ->
        case inherited(codes, votes) do
          nil ->
            {%Events.LegacyIdAssigned{key: key, legacy_id: next, recorded_at: at}, next + 1}

          id ->
            {%Events.LegacyIdAssigned{key: key, legacy_id: id, recorded_at: at}, next}
        end
      end)

    # Two keys can inherit the SAME entity id only if identity genuinely split inside one legacy
    # entity — keep the deterministic winner (lowest key) and re-allocate the rest.
    dedup_inherited(events)
  end

  @doc """
  The key a `legacy_id` lands on TODAY: the assigned key, followed through merges to the survivor.
  Returns `%{key, status}` (status from `Api.identity_status/2`: `:active`, `:merged` — already
  followed — or `:split`, answered with the kept key) or `nil` for an unknown id.
  """
  def resolve(log, legacy_id), do: resolve(log, legacy_id, fold(log))

  @doc "resolve/2 with the `fold/1` state prebuilt, for callers resolving many ids."
  def resolve(log, legacy_id, assigned) do
    assigned
    |> Enum.filter(fn {_k, id} -> id == legacy_id end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> case do
      [] -> nil
      [key | _] -> follow(log, key)
    end
  end

  @doc "The legacy id a key answers to (its own assignment), or nil."
  def legacy_id(log, key), do: log |> fold() |> Map.get(key)

  defp follow(log, key) do
    case Api.identity_status(log, key) do
      %{status: :merged, superseded_by: survivor} -> follow(log, survivor)
      %{status: status} -> %{key: key, status: status}
    end
  end

  # code => %{legacy_entity => grouping-claim count}, from the CURRENT grouping claims.
  defp grouping_votes(claims) do
    claims
    |> Enum.filter(&(&1.kind == :grouping and is_integer(&1.data.product)))
    |> Enum.reduce(%{}, fn c, acc ->
      Map.update(acc, c.data.code, %{c.data.product => 1}, fn tally ->
        Map.update(tally, c.data.product, 1, &(&1 + 1))
      end)
    end)
  end

  # The entity a key's member codes vote for: sum tallies across its codes; most votes wins,
  # ties break to the lowest entity id. No votes -> nil (allocate).
  defp inherited(codes, votes) do
    codes
    |> Enum.flat_map(fn code -> Map.get(votes, code, %{}) |> Map.to_list() end)
    |> Enum.reduce(%{}, fn {entity, n}, acc -> Map.update(acc, entity, n, &(&1 + n)) end)
    |> Enum.max_by(fn {entity, n} -> {n, -entity} end, fn -> nil end)
    |> case do
      nil -> nil
      {entity, _} -> entity
    end
  end

  defp dedup_inherited(events) do
    {kept, _seen, dups} =
      Enum.reduce(events, {[], MapSet.new(), []}, fn e, {kept, seen, dups} ->
        if MapSet.member?(seen, e.legacy_id),
          do: {kept, seen, [e | dups]},
          else: {[e | kept], MapSet.put(seen, e.legacy_id), dups}
      end)

    floor = events |> Enum.map(& &1.legacy_id) |> Enum.max(fn -> 0 end)

    reallocated =
      dups
      |> Enum.reverse()
      |> Enum.with_index(floor + 1)
      |> Enum.map(fn {e, id} -> %{e | legacy_id: id} end)

    Enum.reverse(kept) ++ reallocated
  end
end
