defmodule GoldenRecord.DimensionAliases do
  alias GoldenRecord.Events.ClaimAsserted

  @moduledoc """
  The dimension-alias seam (GH #129): an injected old→new field-name map, applied where claims
  are normalized on the way into a fold, so a source-side field rename does not split one
  dimension across two.

  Claims are write-time canonical — the dimension name current at ingest time is baked into the
  stored claim, and stored events keep that historical spelling forever (the audit trail, same
  posture as medipim's `products_deltas`). The contract (gr-1y5): `normalize/2` the LOG once, at
  the boundary, before ANY fold that groups by dimension — `GoldenRecords.project/3` does this
  and returns the normalized log, so its projection and every read over that log (`Api.get`,
  `History.now`, `Temporal.golden_as_of`) agree; a caller folding a raw log directly normalizes
  it first. Backfill fingerprints hash the pre-alias envelope, so a rename never invalidates
  `backfill_seen` markers — a replay stays a no-op.

  Aliased spots: an attribute claim's `data.field` (including its optional `":locale"` suffix —
  the alias applies to the field part), and the collection name a `member_of` edge points at
  (`data.to = {collection, member}`). Identity claims carry code SCHEMES (`cnk:…`), never field
  names — a field rename must not change a scheme, so identity claims are deliberately not
  aliased.

  Chains (a→b, later b→c) resolve transitively to the terminal name. A cycle is a config error;
  resolution stops after `map_size` hops instead of looping.
  """

  @doc """
  Resolve one dimension name through the alias map: transitive, `"field:locale"`-aware (an exact
  whole-name entry wins over a bare-field entry). Non-binary names pass through untouched.
  """
  def resolve(nil, name), do: name
  def resolve(aliases, name) when map_size(aliases) == 0, do: name

  def resolve(aliases, name) when is_binary(name) do
    case chase(aliases, name, map_size(aliases)) do
      ^name -> resolve_localized(aliases, name)
      moved -> moved
    end
  end

  def resolve(_aliases, name), do: name

  defp resolve_localized(aliases, name) do
    case String.split(name, ":", parts: 2) do
      [field, locale] -> "#{chase(aliases, field, map_size(aliases))}:#{locale}"
      _ -> name
    end
  end

  # A chain can be at most map_size links long; running out of hops means a cycle — stop.
  defp chase(_aliases, name, 0), do: name

  defp chase(aliases, name, hops) do
    case aliases do
      %{^name => next} -> chase(aliases, next, hops - 1)
      _ -> name
    end
  end

  @doc """
  Rewrite every dimension-bearing claim in `events` to its terminal alias. Everything else
  (identity, grouping, media, non-member_of edges, non-claim events) passes through unchanged.
  """
  def normalize(events, nil), do: events
  def normalize(events, aliases) when map_size(aliases) == 0, do: events
  def normalize(events, aliases), do: Enum.map(events, &normalize_event(&1, aliases))

  defp normalize_event(%ClaimAsserted{kind: :attribute, data: %{field: f} = d} = c, aliases),
    do: %{c | data: %{d | field: resolve(aliases, f)}}

  defp normalize_event(
         %ClaimAsserted{kind: :edge, data: %{relation: :member_of, to: {coll, member}} = d} = c,
         aliases
       ),
       do: %{c | data: %{d | to: {resolve(aliases, coll), member}}}

  # A previously persisted log may still carry un-lowered :member_of claims (see Substrate).
  defp normalize_event(
         %ClaimAsserted{kind: :member_of, data: %{collection: {coll, member}} = d} = c,
         aliases
       ),
       do: %{c | data: %{d | collection: {resolve(aliases, coll), member}}}

  defp normalize_event(event, _aliases), do: event
end
