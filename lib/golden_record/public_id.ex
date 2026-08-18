defmodule GoldenRecord.PublicId do
  alias GoldenRecord.{Events, Substrate, Survivorship, Api}

  @moduledoc """
  Identity-grade, customer-facing schemes like CNK. The surrogate key is internal; CNK is the
  public key — strictly unique, never shared. Two sources giving different CNKs for the same
  product is fine: they become canonical + alias(es) on one key, with the canonical chosen by
  priority. The customer resolves by ANY of them.
  """

  @doc "Canonical public id of `scheme` for `key` (by source priority), plus its aliases."
  def canonical(scheme, key, log, priority),
    do: do_canonical(scheme, key, Api.members(log), fn -> identity_claims(log) end, priority)

  @doc """
  canonical/4 with the fold state prebuilt — `members` (`Api.members/1`) and the current
  identity claims — so callers enriching many keys fold the log once instead of per key.
  """
  def canonical(scheme, key, members, idclaims, priority),
    do: do_canonical(scheme, key, members, fn -> idclaims end, priority)

  # idclaims arrives as a thunk: the log arity only pays for the identity-claims fold on the
  # multi-code path, exactly as before.
  defp do_canonical(scheme, key, members, idclaims_fun, priority) do
    codes =
      members
      |> Map.get(key, MapSet.new())
      |> Enum.filter(fn {s, _} -> s == scheme end)
      |> Enum.sort()

    case codes do
      [] ->
        nil

      [code] ->
        %{canonical: code, aliases: []}

      _multiple ->
        idclaims = idclaims_fun.()

        entries =
          for code <- codes, src <- sources_of(code, idclaims), do: %{source: src, value: code, order: 0}

        case entries do
          [] ->
            %{
              canonical: nil,
              aliases: codes,
              status: :needs_review,
              candidates: Enum.map(codes, &{nil, &1})
            }

          _ ->
            decision = Survivorship.decide(scheme, entries, priority)

            if decision.status == :needs_review do
              %{
                canonical: nil,
                aliases: codes,
                status: :needs_review,
                candidates: decision.candidates
              }
            else
              %{canonical: decision.value, aliases: List.delete(codes, decision.value)}
            end
        end
    end
  end

  @doc "Identity-grade INVARIANT check: a code of `scheme` must never own >1 key. Returns violations."
  def collisions(scheme, log) when is_list(log), do: collisions(scheme, Api.members(log))

  def collisions(scheme, members) when is_map(members) do
    members
    |> Enum.flat_map(fn {k, codes} -> for {s, _} = c <- codes, s == scheme, do: {c, k} end)
    |> Enum.group_by(fn {c, _} -> c end, fn {_, k} -> k end)
    |> Enum.filter(fn {_c, keys} -> length(Enum.uniq(keys)) > 1 end)
    |> Enum.map(fn {c, keys} -> %{code: c, keys: Enum.sort(Enum.uniq(keys))} end)
  end

  defp sources_of(code, idclaims), do: for(c <- idclaims, code in c.data.codes, do: c.source)

  @doc "Current identity claims — the second piece of fold state canonical/5 takes prebuilt."
  def identity_claims(log),
    do: for(%Events.ClaimAsserted{kind: :identity} = e <- log, do: e) |> Substrate.current()
end
