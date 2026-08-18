# lib/ingest/legacy_xref.ex — the durable legacy -> new cross-reference (gr-0c2).
#
# Stage 4b of the legacy-medipim ingest, a fold over the re-derivation output (gr-chq:
# `Rederivation.run/2` / `from_claims/2` -> `%{log, ledger, clusters, shared}`). Per the design
# (docs/plans/2026-06-05-legacy-history-ingest-design.md, "LegacyXref — the durable legacy -> new
# map"): the legacy `entity` was NEVER a clustering input — it rode along only as the :grouping
# claims ClaimMapping synthesized (one per listing-code, `%{code, product: legacy_entity}`). Here
# we read those grouping claims back out and join them against the re-derived surrogate keys to
# answer the migration question: where did every existing legacy `entity` id land, and did it stay
# put (stable), get absorbed with others (merged), or fragment across keys (split)?
#
# OUTPUT — two folds plus a resolver:
#
#   key_to_legacy:  SK   -> sorted-unique [legacy_entity, ...]   (provenance of each surrogate key)
#   legacy_to_key:  ent  -> %{primary: SK, all: [SK, ...], relation: :stable | :split |
#                            {:merged, [other_ent, ...]}}
#   resolve_legacy(xref, ent) -> {:ok, primary, status} | {:error, :unknown_legacy}
#
# `relation` IS the migration diff classification (confirm / merge / split / collision) the design
# promises "for free" — but the diff VIEW / rendering is gr-swc, and the golden-record projection
# (Catalog/Api output) is gr-8r6. This module produces ONLY the maps + resolver; it does not render
# a diff and does not project records.
#
# SPLIT PRIMARY — the engine's split "keep" heuristic, re-implemented here to the design's spec
# (CNK ▸ GTIN spine, then most listings, then lowest key). NOTE: the engine's IdentityLedger has a
# private `has_spine?/1` that only checks `:gtin`; the design wants CNK to outrank GTIN, so we
# compute spine rank ourselves rather than borrow it. "Most listings" = the count of DISTINCT
# grouping-claim sources contributing codes to that key — i.e. how many real org listings the
# surrogate key is backed by (a listing = a (legacy_entity, source) pair, and ClaimMapping stamps
# each grouping claim with its listing `source`).

alias GoldenRecord.{Events, Lanes}

defmodule LegacyXref do
  @doc """
  Build the cross-reference from a re-derivation result `%{log: log, ledger: ledger}` (the map
  returned by `Rederivation.run/2` / `Rederivation.from_claims/2`; extra keys like `clusters` /
  `shared` are ignored).

  Returns `%{key_to_legacy: %{SK => [legacy_entity]}, legacy_to_key: %{legacy_entity => %{primary,
  all, relation}}}`. See the moduledoc for the shapes and the `relation` taxonomy.
  """
  def build(%{log: log, ledger: ledger}) do
    groupings = groupings(log)

    # legacy_entity -> MapSet of its canonical {scheme, code} (drawn from its grouping claims). Used
    # by the over-merge guard to find the bridge — the codes shared across the merged entities.
    entity_codes =
      Enum.reduce(groupings, %{}, fn g, acc ->
        Map.update(acc, g.data.product, MapSet.new([g.data.code]), &MapSet.put(&1, g.data.code))
      end)

    # SK -> %{codes: MapSet, sources: MapSet} drawn from the grouping claims landing on its members.
    # PRODUCT lane only (gr-2a8): legacy entities are products — description/media/substance keys
    # have no legacy id to cross-reference.
    # Grouped by code once, so each key concatenates its member codes' lists instead of
    # refiltering every grouping claim per key.
    groupings_by_code = Enum.group_by(groupings, & &1.data.code)

    per_key =
      for {key, member_codes} <- Lanes.partition_members(ledger.members).product, into: %{} do
        contributing = Enum.flat_map(member_codes, &Map.get(groupings_by_code, &1, []))

        {key,
         %{
           entities: contributing |> Enum.map(& &1.data.product) |> Enum.uniq() |> Enum.sort(),
           sources: contributing |> Enum.map(& &1.source) |> MapSet.new(),
           codes: member_codes
         }}
      end

    key_to_legacy = Map.new(per_key, fn {key, info} -> {key, info.entities} end)
    legacy_to_key = invert(key_to_legacy, per_key, entity_codes)

    %{key_to_legacy: key_to_legacy, legacy_to_key: legacy_to_key}
  end

  @doc """
  Convenience: run `Rederivation.run(envelopes, at)` internally, then `build/1` its result. For
  callers that only want the xref and have raw `%HistoryEnvelope{}`s.
  """
  def from_envelopes(envelopes, at) when is_list(envelopes) do
    envelopes |> Rederivation.run(at) |> build()
  end

  @doc """
  Resolve a legacy `entity` id to its surrogate key, disclosing alternates:

    * stable  -> `{:ok, SK, :stable}`
    * split   -> `{:ok, primary_SK, {:split, [all_SKs...]}}`  (answer with the primary, list all)
    * merged  -> `{:ok, SK, {:merged, [other_legacy_ids...]}}` (the co-tenants on that key)
    * merged (suspect) -> `{:ok, SK, {:merged, [other_legacy_ids...], :suspect}}` (gr-ose: the
                  co-tenants were bridged SOLELY by a reusable barcode/GS1 code — an over-merge the
                  migration diff must surface as needs-review; the 3-tuple passes through unchanged)

  Unknown id -> `{:error, :unknown_legacy}`. Mirrors how a stale CNK redirects today: callers get a
  single authoritative key plus enough context to see what else it now relates to.
  """
  def resolve_legacy(%{legacy_to_key: legacy_to_key}, legacy_id) do
    case Map.fetch(legacy_to_key, legacy_id) do
      {:ok, %{primary: primary, all: all, relation: :split}} -> {:ok, primary, {:split, all}}
      {:ok, %{primary: primary, relation: relation}} -> {:ok, primary, relation}
      :error -> {:error, :unknown_legacy}
    end
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp groupings(log) do
    Enum.filter(log, &match?(%Events.ClaimAsserted{kind: :grouping}, &1))
  end

  # legacy_entity -> %{primary, all, relation}. `all` = every SK the entity's grouping claims point
  # at (sorted). `relation` is decided from that placement plus each key's co-tenancy.
  defp invert(key_to_legacy, per_key, entity_codes) do
    entity_to_keys =
      Enum.reduce(key_to_legacy, %{}, fn {key, entities}, acc ->
        Enum.reduce(entities, acc, fn e, acc -> Map.update(acc, e, [key], &[key | &1]) end)
      end)

    Map.new(entity_to_keys, fn {entity, keys} ->
      all = keys |> Enum.uniq() |> Enum.sort_by(&key_num/1)

      {entity,
       %{
         primary: primary(all, entity, key_to_legacy, per_key),
         all: all,
         relation: relation(all, entity, key_to_legacy, entity_codes)
       }}
    end)
  end

  # PRECEDENCE: split outranks merged. A legacy entity spread over >1 key has FRAGMENTED — that is
  # the dominant fact a migrator must act on, regardless of whether any one of those keys also holds
  # OTHER legacy entities. (A degenerate case — split AND a co-tenant on one of the keys — is
  # therefore reported as :split; the co-tenancy still surfaces via key_to_legacy for that key.)
  defp relation([_single = key], entity, key_to_legacy, entity_codes) do
    case Enum.sort(Enum.reject(key_to_legacy[key], &(&1 == entity))) do
      [] -> :stable
      others -> merged(entity, others, entity_codes)
    end
  end

  defp relation(_many, _entity, _key_to_legacy, _entity_codes), do: :split

  # OVER-MERGE GUARD (gr-ose): the merge IS applied (codes won, one SK) — we only TAG it. The bridge
  # is the set of codes shared between `entity` and ANY co-tenant on this key. If any shared bridge
  # code is national-grade, the merge is trusted: `{:merged, others}`. If the entities are bridged
  # SOLELY by barcode/GS1 codes, tag it suspect: `{:merged, others, :suspect}`. A national share
  # always wins (it is the re-derivation working as intended), so a national bridge alone keeps the
  # plain 2-tuple even if a barcode is also shared.
  defp merged(entity, others, entity_codes) do
    mine = Map.get(entity_codes, entity, MapSet.new())

    bridge =
      Enum.reduce(others, MapSet.new(), fn other, acc ->
        shared = MapSet.intersection(mine, Map.get(entity_codes, other, MapSet.new()))
        MapSet.union(acc, shared)
      end)

    if Enum.any?(bridge, fn {scheme, _code} -> CodeRegistry.national_grade?(scheme) end) do
      {:merged, others}
    else
      {:merged, others, :suspect}
    end
  end

  # Non-split: the sole key. Split: the engine "keep" heuristic per the design — spine (CNK ▸ GTIN),
  # then most listings (distinct grouping-claim sources backing the key), then lowest key id.
  defp primary([single], _entity, _key_to_legacy, _per_key), do: single

  defp primary(all, _entity, _key_to_legacy, per_key) do
    Enum.max_by(all, fn key ->
      info = per_key[key]
      {spine_rank(info.codes), MapSet.size(info.sources), -key_num(key)}
    end)
  end

  # CNK is a stronger identity spine than GTIN (the design's CNK ▸ GTIN ordering). 2 = has a CNK,
  # 1 = has a GTIN but no CNK, 0 = neither.
  defp spine_rank(codes) do
    cond do
      Enum.any?(codes, &match?({:cnk, _}, &1)) -> 2
      Enum.any?(codes, &match?({:gtin, _}, &1)) -> 1
      true -> 0
    end
  end

  defp key_num("SK_" <> n), do: String.to_integer(n)
end
