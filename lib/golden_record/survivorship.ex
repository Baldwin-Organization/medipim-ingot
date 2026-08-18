defmodule GoldenRecord.Survivorship do
  alias GoldenRecord.{Priority}

  @moduledoc """
  Field survivorship. `policy` is the seam that keeps medipim-specific scoring out of the generic
  engine — attribute rankings are ALWAYS applied, never switched off:

    * `%Priority{}` — tier ranking (back-compat; behaviour unchanged).
    * a 2-arity `fun.(dimension, source)` returning a rank (lower wins) — an INJECTED rank function.
      medipim's per-field/per-org scoring (incl. the off-product penalty, labo/region context) closes
      over its context inside such a function; the generic engine only consumes the ranks.
  """
  def field_decisions(codes, attrs, policy) do
    attrs
    |> Enum.filter(&MapSet.member?(codes, &1.data.code))
    |> Enum.group_by(& &1.data.field)
    |> Enum.map(fn {field, cs} ->
      {field,
       decide(field, Enum.map(cs, &%{source: &1.source, value: &1.data.value, order: &1.order}), policy)}
    end)
  end

  def decide(dimension, entries, policy) do
    rank = rank_fun(policy)

    latest =
      entries
      |> Enum.group_by(& &1.source)
      |> Enum.map(fn {_source, source_entries} ->
        Enum.max_by(source_entries, &{&1.order, &1.value})
      end)

    ranked = Enum.sort_by(latest, fn e -> {rank.(dimension, e.source), e.source, e.value} end)
    winner = hd(ranked)
    top = rank.(dimension, winner.source)

    distinct =
      latest
      |> Enum.filter(fn e -> rank.(dimension, e.source) == top end)
      |> Enum.map(& &1.value)
      |> Enum.uniq()

    unresolved? = length(distinct) > 1

    %{
      value: if(unresolved?, do: nil, else: winner.value),
      winner: if(unresolved?, do: nil, else: winner.source),
      status: if(unresolved?, do: :needs_review, else: :resolved),
      candidates: Enum.map(ranked, &{&1.source, &1.value})
    }
  end

  @doc """
  A rank function `(dimension, source) -> rank` from a `policy`: a `%Priority{}` ranks by tier
  (back-compat); a 2-arity fun is an injected rank function carrying its own context. Public so any
  fold step that ranks (e.g. media survivorship) consumes the SAME policy seam — never `Priority`
  directly — so an injected policy threads end-to-end.
  """
  def rank_fun(%Priority{} = priority), do: &Priority.rank(priority, &1, &2)
  def rank_fun(fun) when is_function(fun, 2), do: fun
end
