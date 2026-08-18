defmodule GoldenRecord.Catalog do
  alias GoldenRecord.{Events, Lanes, Survivorship}

  # overrides: %{attr: %{{key, field} => ConflictResolved}, product: %{key => product}}
  #
  # `members` may span every lane (gr-2a8): the product lane becomes the variants below; the
  # other lanes feed the edge-traversal resolvers (substances/descriptions/depicted media) and
  # are projectable standalone via `lane_records/3`. Visibility is DERIVED at read time — a new
  # `contains` edge instantly pulls the substance's descriptions onto that product's page,
  # because nothing is copied; the projection is a fold (gr-sw0).
  def project(members, live_claims, priority, overrides) do
    lanes = Lanes.partition_members(members)
    attrs = Enum.filter(live_claims, &(&1.kind == :attribute))
    groups = Enum.filter(live_claims, &(&1.kind == :grouping))
    media = Enum.filter(live_claims, &(&1.kind == :media))
    edges = Enum.filter(live_claims, &(&1.kind == :edge))

    # Inverted code -> key maps, built once per projection so edge-endpoint resolution is a
    # lookup instead of a scan over the lane's members per edge.
    owners = %{
      substance: owner_index(lanes.substance),
      description: owner_index(lanes.description),
      media: owner_index(lanes.media)
    }

    # Suppress edges with their description endpoint pre-resolved; the product-code side is the
    # only part that varies per variant.
    suppress_edges =
      for s <- edges,
          s.data.relation == :suppress,
          do: {owner_key(owners.description, s.data.from), s.data.to}

    lanes.product
    |> Enum.map(fn {key, codes} ->
      substances = resolve_substances(codes, edges, owners.substance)

      %{
        key: key,
        codes: Enum.sort(MapSet.to_list(codes)),
        attributes: resolve_attributes(key, codes, attrs, priority, overrides.attr),
        product: resolve_product(key, codes, groups, priority, overrides.product),
        media:
          resolve_media(codes, media, priority) ++
            resolve_depicted(codes, edges, lanes.media, owners.media, attrs, priority),
        categories: resolve_categories(codes, edges),
        substances: substances,
        descriptions:
          resolve_descriptions(codes, lanes, owners, substances, suppress_edges, edges, attrs, priority)
      }
    end)
    |> Enum.group_by(& &1.product.value)
    |> Enum.sort_by(fn {product, _} -> product end)
    |> Enum.map(fn {product, vs} -> %{product: product, variants: Enum.sort_by(vs, & &1.key)} end)
  end

  @doc """
  Standalone view of a non-product lane's records (gr-2a8): each is a first-class golden record
  — identity codes, resolved attributes with survivorship — exactly what the product page embeds
  via edges, minus the traversal.
  """
  def lane_records(lane_members, live_claims, priority) do
    attrs = Enum.filter(live_claims, &(&1.kind == :attribute))

    lane_members
    |> Enum.map(fn {key, codes} ->
      %{
        key: key,
        codes: Enum.sort(MapSet.to_list(codes)),
        attributes: lane_attributes(codes, attrs, priority)
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp resolve_attributes(key, codes, attrs, priority, attr_overrides) do
    codes
    |> Survivorship.field_decisions(attrs, priority)
    |> Enum.map(fn {field, base} -> {field, apply_override(base, Map.get(attr_overrides, {key, field}))} end)
    |> Enum.sort()
  end

  defp apply_override(base, nil), do: base

  defp apply_override(base, %Events.ConflictResolved{decision: {:pick, v}, by: by}),
    do: %{base | value: v, winner: "steward:#{by}", status: :resolved_by_steward}

  defp resolve_product(key, codes, groups, priority, product_overrides) do
    case Map.get(product_overrides, key) do
      nil -> resolve_product_from_claims(codes, groups, priority)
      product -> %{value: product, winner: :steward, status: :resolved_by_steward, candidates: []}
    end
  end

  # Media attaches by code, exactly like an attribute — so it RE-HOMES automatically when a
  # split/merge moves its target code to a different surrogate key. Dedup by asset identity;
  # the highest-priority source wins each asset's metadata.
  defp resolve_media(codes, media, priority) do
    rank = Survivorship.rank_fun(priority)

    media
    |> Enum.filter(&MapSet.member?(codes, &1.data.target))
    |> Enum.group_by(& &1.data.asset)
    |> Enum.map(fn {asset, claims} ->
      best = Enum.min_by(claims, &rank.(:media, &1.source))
      %{asset: asset, role: best.data.role, source: best.source, uri: best.data.uri}
    end)
    |> Enum.sort_by(fn m -> {m.role != :primary, m.asset} end)
  end

  # Collection membership (e.g. ATC categories) is the :member_of edge relation (gr-xde): it
  # attaches by code so it re-homes on a split, and unions across sources by default.
  defp resolve_categories(codes, edges) do
    edges
    |> Enum.filter(&(&1.data.relation == :member_of and MapSet.member?(codes, &1.data.from)))
    |> Enum.map(& &1.data.to)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The substances this variant claims, via :contains edges — both hops resolve code → current
  # owner key at read time, so a substance merge converges every product's view with zero writes.
  defp resolve_substances(codes, edges, sub_index) do
    edges
    |> Enum.filter(&(&1.data.relation == :contains and MapSet.member?(codes, &1.data.from)))
    |> Enum.group_by(&owner_key(sub_index, &1.data.to))
    |> Enum.map(fn {key, es} ->
      %{
        key: key,
        codes: es |> Enum.map(& &1.data.to) |> Enum.uniq() |> Enum.sort(),
        sources: es |> Enum.map(& &1.source) |> Enum.uniq() |> Enum.sort()
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  # The derived description set (gr-sw0): descriptions tagged directly to this variant (one hop,
  # :describes), plus descriptions tagged to any substance it contains (two hops, via :contains)
  # — a named, bounded traversal, never blanket closure. Each entry carries its provenance (`via` — WHY it is
  # on this page) and drops steward-suppressed pairings (gr-745) for THIS product only.
  defp resolve_descriptions(codes, lanes, owners, substances, suppress_edges, edges, attrs, priority) do
    describes = Enum.filter(edges, &(&1.data.relation == :describes))
    contained = MapSet.new(substances, & &1.key)

    suppressed_keys =
      for {desc_key, to} <- suppress_edges, MapSet.member?(codes, to), into: MapSet.new(), do: desc_key

    direct = for e <- describes, MapSet.member?(codes, e.data.to), do: {e, :direct}

    via =
      for e <- describes,
          key = owner_key(owners.substance, e.data.to),
          MapSet.member?(contained, key),
          do: {e, {:substance, key}}

    (direct ++ via)
    |> Enum.reject(fn {e, _route} ->
      MapSet.member?(suppressed_keys, owner_key(owners.description, e.data.from))
    end)
    |> Enum.group_by(fn {e, route} -> {owner_key(owners.description, e.data.from), route} end)
    |> Enum.map(fn {{key, route}, entries} ->
      desc_codes = Map.get(lanes.description, key) || MapSet.new([key])

      %{
        key: key,
        via: route,
        asserted_by: entries |> Enum.map(fn {e, _} -> e.source end) |> Enum.uniq() |> Enum.sort(),
        attributes: lane_attributes(desc_codes, attrs, priority)
      }
    end)
    |> Enum.sort_by(&{&1.via != :direct, &1.via, &1.key})
  end

  # Media-lane records reach the page via :depicts edges — the first-class path (gr-kek). The
  # legacy :media claim kind keeps resolving in resolve_media/3 until every producer emits lanes.
  defp resolve_depicted(codes, edges, media_members, media_index, attrs, priority) do
    edges
    |> Enum.filter(&(&1.data.relation == :depicts and MapSet.member?(codes, &1.data.to)))
    |> Enum.group_by(&owner_key(media_index, &1.data.from))
    |> Enum.map(fn {key, es} ->
      attributes = lane_attributes(Map.get(media_members, key) || MapSet.new([key]), attrs, priority)

      %{
        asset: key,
        role: attr_value(attributes, "role", :secondary),
        source: es |> Enum.map(& &1.source) |> Enum.uniq() |> Enum.sort() |> hd(),
        uri: attr_value(attributes, "uri", nil)
      }
    end)
    |> Enum.sort_by(& &1.asset)
  end

  # Resolve an edge endpoint to the key that currently owns it; an endpoint with no identity
  # claim yet resolves to itself — the code IS the identity until a record exists for it.
  # put_new keeps the FIRST key that carries a code, matching the Enum.find_value scan the
  # index replaces (a held conflict can leave one code in two keys' sets).
  defp owner_index(members) do
    for {key, set} <- members, code <- set, reduce: %{} do
      acc -> Map.put_new(acc, code, key)
    end
  end

  defp owner_key(index, code), do: Map.get(index, code, code)

  defp lane_attributes(codes, attrs, priority),
    do: codes |> Survivorship.field_decisions(attrs, priority) |> Enum.sort()

  defp attr_value(attributes, field, default) do
    case List.keyfind(attributes, field, 0) do
      {_, %{value: v}} -> v
      nil -> default
    end
  end

  defp resolve_product_from_claims(codes, groups, priority) do
    groups
    |> Enum.filter(&MapSet.member?(codes, &1.data.code))
    |> Enum.map(&%{source: &1.source, value: &1.data.product, order: &1.order})
    |> case do
      [] ->
        %{value: {:none, "—"}, winner: nil, status: :resolved, candidates: []}

      entries ->
        base = Survivorship.decide(:product, entries, priority)
        # Contested: a single variant pointing at >1 product is a code collision — surface it.
        if entries |> Enum.map(& &1.value) |> Enum.uniq() |> length() > 1,
          do: %{base | value: nil, winner: nil, status: :needs_review},
          else: base
    end
  end
end
