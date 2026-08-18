defmodule GoldenRecord.Cluster do
  alias GoldenRecord.{Codes}

  @doc """
  Group identity codes into variant clusters.

  `shared` codes are members but never bridge. By default a bridge is also held when joining its
  two components would put different values of a unique scheme (national ids, ISBNs) into one
  identity, or when a REASSIGNABLE code (a GS1 barcode) is the only thing joining two components
  that each already stand on their own identifier. Pass `guard?: false` only for explicit
  before/after comparison tooling.
  """
  def variants(live_claims, shared \\ MapSet.new())
  def variants(live_claims, shared), do: variants(live_claims, shared, [])

  def variants(live_claims, shared, opts) do
    sets =
      live_claims
      |> Enum.filter(&(&1.kind == :identity))
      |> Enum.map(fn c -> MapSet.new(c.data.codes) end)
      |> Enum.reject(&(MapSet.size(&1) == 0))
      |> Enum.uniq()
      |> Enum.sort_by(&code_signature/1)

    if Keyword.get(opts, :guard?, true) do
      unique_scheme? = Keyword.get(opts, :unique_scheme?, &Codes.national_grade?/1)
      barcode_scheme? = Keyword.get(opts, :barcode_scheme?, &Codes.barcode_grade?/1)
      trusted_sources = Keyword.get(opts, :trusted_sources, MapSet.new([:steward]))

      evidence =
        Enum.filter(live_claims, fn claim ->
          claim.kind == :identity_evidence and MapSet.member?(trusted_sources, claim.source)
        end)

      distinct_pairs =
        for %{data: %{relation: :distinct, left: left, right: right}} <- evidence,
            into: MapSet.new(),
            do: code_pair(left, right)

      same_pairs =
        for %{data: %{relation: :same, left: left, right: right}} <- evidence,
            do: code_pair(left, right)

      guarded_components(sets, shared, unique_scheme?, barcode_scheme?, distinct_pairs, same_pairs)
    else
      sets |> connected_components(shared) |> Enum.sort_by(&Enum.min/1)
    end
  end

  defp guarded_components([], _shared, _unique, _barcode, _distinct_pairs, _same_pairs), do: []

  defp guarded_components(sets, shared, unique_scheme?, barcode_scheme?, distinct_pairs, same_pairs) do
    indexed = Enum.with_index(sets)
    parent = Map.new(indexed, fn {_set, index} -> {index, index} end)
    codes = Map.new(indexed, fn {set, index} -> {index, set} end)

    allowed_pairs =
      sets
      |> allowed_unique_pairs(unique_scheme?)
      |> MapSet.union(MapSet.new(same_pairs))

    {parent, codes} =
      sets
      |> candidate_edges(shared, unique_scheme?, same_pairs)
      |> Enum.reduce({parent, codes}, fn {_kind, bridge, left, right, override?}, {parents, by_root} ->
        left_root = root(parents, left)
        right_root = root(parents, right)

        if left_root == right_root do
          {parents, by_root}
        else
          left_codes = Map.fetch!(by_root, left_root)
          right_codes = Map.fetch!(by_root, right_root)
          merged = MapSet.union(left_codes, right_codes)

          if distinct_conflict?(merged, distinct_pairs) or
               (not override? and
                  (unique_conflict?(merged, unique_scheme?, allowed_pairs) or
                     reassignable_bridge?(bridge, left_codes, right_codes, barcode_scheme?))) do
            {parents, by_root}
          else
            keep = min(left_root, right_root)
            drop = max(left_root, right_root)

            {
              Map.put(parents, drop, keep),
              by_root |> Map.put(keep, merged) |> Map.delete(drop)
            }
          end
        end
      end)

    parent
    |> Map.keys()
    |> Enum.map(&root(parent, &1))
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(codes, &1))
    |> Enum.sort_by(&Enum.min/1)
  end

  # Adjacent nodes are sufficient to connect every ordinary code group, while sorting by its
  # unique-id signature lets compatible records (e.g. the same CNK) converge on either side of a
  # held contradiction. The order is data-derived, never input-derived.
  defp candidate_edges(sets, shared, unique_scheme?, same_pairs) do
    by_code =
      sets
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {set, index}, acc ->
        Enum.reduce(set, acc, fn code, by_code -> Map.update(by_code, code, [index], &[index | &1]) end)
      end)

    signatures =
      sets
      |> Enum.with_index()
      |> Map.new(fn {set, index} ->
        {index, {unique_signature(set, unique_scheme?), code_signature(set)}}
      end)

    ordinary =
      by_code
      |> Enum.reject(fn {code, _indexes} -> MapSet.member?(shared, code) end)
      |> Enum.flat_map(fn {code, indexes} ->
        indexes
        |> Enum.sort_by(&Map.fetch!(signatures, &1))
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [left, right] -> {0, code, left, right, false} end)
      end)

    explicit_same =
      for {left_code, right_code} = pair <- same_pairs,
          left <- Map.get(by_code, left_code, []),
          right <- Map.get(by_code, right_code, []),
          left != right,
          do: {1, pair, left, right, true}

    Enum.sort(ordinary ++ explicit_same)
  end

  # A GS1 barcode is reassignable — NHSBSA publishes a log of GTINs that moved between packs — so
  # it must not be the ONE thing that fuses two components which each already carry an identifier
  # of their own. When either side has nothing but barcodes, the bridge is still the best evidence
  # there is and the join stands: refusing it would orphan a listing for no gain.
  #
  # The held code stays in both clusters, so IdentityLedger's cluster_conflicts picks it up and
  # raises the same identity_conflict flag and merge proposal as a national-code clash.
  defp reassignable_bridge?({scheme, _}, left, right, barcode_scheme?) do
    barcode_scheme?.(scheme) and stands_alone?(left, barcode_scheme?) and
      stands_alone?(right, barcode_scheme?)
  end

  defp reassignable_bridge?(_bridge, _left, _right, _barcode_scheme?), do: false

  defp stands_alone?(codes, barcode_scheme?),
    do: Enum.any?(codes, fn {scheme, _} -> not barcode_scheme?.(scheme) end)

  defp unique_conflict?(codes, unique_scheme?, allowed_pairs) do
    codes
    |> Enum.filter(fn {scheme, _value} -> unique_scheme?.(scheme) end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.any?(fn {_scheme, scheme_codes} ->
      scheme_codes
      |> Enum.sort()
      |> pairs()
      |> Enum.any?(&(not MapSet.member?(allowed_pairs, &1)))
    end)
  end

  # Co-asserting two unique ids in ONE source record is explicit positive evidence that they are
  # aliases for the same thing. A later bridge may reuse that pair without being held.
  defp allowed_unique_pairs(sets, unique_scheme?) do
    for set <- sets,
        {_scheme, scheme_codes} <-
          set
          |> Enum.filter(fn {scheme, _} -> unique_scheme?.(scheme) end)
          |> Enum.group_by(&elem(&1, 0)),
        pair <- scheme_codes |> Enum.sort() |> pairs(),
        into: MapSet.new(),
        do: pair
  end

  defp pairs(values) do
    for {left, index} <- Enum.with_index(values), right <- Enum.drop(values, index + 1), do: {left, right}
  end

  defp distinct_conflict?(codes, distinct_pairs),
    do: Enum.any?(distinct_pairs, fn {left, right} -> left in codes and right in codes end)

  defp code_pair(left, right) when left <= right, do: {left, right}
  defp code_pair(left, right), do: {right, left}

  defp unique_signature(codes, unique_scheme?),
    do: codes |> Enum.filter(fn {scheme, _} -> unique_scheme?.(scheme) end) |> Enum.sort()

  defp code_signature(codes), do: Enum.sort(codes)

  # ponytail: union-find without path compression — O(n²) worst case on chained merges. Per-lane
  # cluster sizes make that irrelevant; thread compressed parents through the reduce if it ever
  # shows up in a profile (GH #59).
  defp root(parent, node) do
    case Map.fetch!(parent, node) do
      ^node -> node
      next -> root(parent, next)
    end
  end

  defp connected_components(sets, shared) do
    Enum.reduce(sets, [], fn set, acc ->
      bridges? = fn comp -> not MapSet.disjoint?(bare(comp, shared), bare(set, shared)) end
      {overlapping, disjoint} = Enum.split_with(acc, bridges?)
      [Enum.reduce(overlapping, set, &MapSet.union(&2, &1)) | disjoint]
    end)
  end

  defp bare(codes, shared), do: MapSet.difference(codes, shared)
end
