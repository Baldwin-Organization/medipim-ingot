defmodule GoldenRecord.Relations do
  alias GoldenRecord.{Lanes}

  @moduledoc """
  The relation registry (gr-dig): each edge relation declares a type signature — which lanes its
  endpoints may live in — and product-page traversal is relation-scoped, named config, never
  blanket closure (a common excipient must not drag its descriptions onto thousands of
  products). Adding a relation is a data change here, not an engine change.
  """

  # relation => {allowed from-lanes, allowed to-lanes}. :member_of's target is a collection
  # namespace, not a coded entity — its to-side is unchecked (nil = any).
  @signatures %{
    contains: {[:product], [:substance]},
    describes: {[:description], [:product, :substance]},
    depicts: {[:media], [:product, :substance]},
    member_of: {[:product], nil},
    suppress: {[:description], [:product]}
  }

  @by_name Map.new(@signatures, fn {rel, _sig} -> {Atom.to_string(rel), rel} end)

  def signatures, do: @signatures

  @doc ~s{Relation atom for a wire name ("contains" => :contains) — never an atom leak.}
  def parse(name), do: parse(name, nil)

  def parse(name, %SchemeRegistry{} = registry) do
    case SchemeRegistry.relation(registry, name) do
      {:ok, %{name: relation}} -> {:ok, relation}
      :error -> Map.fetch(@by_name, name)
    end
  end

  def parse(name, nil), do: Map.fetch(@by_name, name)

  @doc "Do an edge's endpoints satisfy the relation's lane signature? (`:uuid` is lane-neutral.)"
  def valid_signature?(relation, from, to), do: valid_signature?(relation, from, to, nil)

  def valid_signature?(relation, {from_scheme, _}, to, registry) do
    case signature(relation, registry) do
      :error ->
        false

      {:ok, {froms, tos}} ->
        lane_ok?(Lanes.lane_of_scheme(from_scheme, registry), froms) and
          (tos == nil or
             (match?({_, _}, to) and lane_ok?(Lanes.lane_of_scheme(elem(to, 0), registry), tos)))
    end
  end

  defp signature(relation, %SchemeRegistry{} = registry) do
    case SchemeRegistry.relation(registry, relation) do
      {:ok, %{from: from, to: to}} -> {:ok, {from, to}}
      :error -> Map.fetch(@signatures, relation)
    end
  end

  defp signature(relation, nil), do: Map.fetch(@signatures, relation)

  defp lane_ok?(nil, _allowed), do: true
  defp lane_ok?(lane, allowed), do: lane in allowed
end
