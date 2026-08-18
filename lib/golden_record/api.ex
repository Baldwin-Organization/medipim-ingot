defmodule GoldenRecord.Api do
  alias GoldenRecord.{Events, Codes, IdentityLedger, History}

  @moduledoc """
  The read layer we sell to customers. Two rules make splits/merges survivable:
    * customers address by CODE (resolved to the current owner), not by surrogate key, and
    * every key carries an identity status so a stale key redirects instead of breaking.
  Plus a change feed (the identity events) so customers can reconcile their local copies.
  """

  @doc "Identity status of a key, derived from the log: :active | :merged (-> survivor) | :split (-> parts)."
  def identity_status(log, key) do
    superseded_by =
      Enum.find_value(log, fn
        %Events.IdentitiesMerged{from: from, into: into} -> if key in from and key != into, do: into
        _ -> nil
      end)

    split_into =
      Enum.find_value(log, fn
        %Events.IdentitySplit{key: ^key, into: into} -> [key | Enum.map(into, &elem(&1, 0))]
        _ -> nil
      end)

    cond do
      superseded_by != nil -> %{status: :merged, superseded_by: superseded_by}
      split_into != nil -> %{status: :split, split_into: split_into}
      true -> %{status: :active}
    end
  end

  @doc """
  Resolve any code (canonical OR alias) to the surrogate key that currently owns it.

  Accepts the raw log or, for callers doing many lookups, a prebuilt members map
  (`Api.members/1`) so the ledger folds once instead of per call.
  """
  def resolve_key(log, code) when is_list(log), do: resolve_key(members(log), code)

  def resolve_key(members, code) when is_map(members) do
    canon = Codes.canonicalize(code)
    Enum.find_value(members, fn {k, codes} -> if MapSet.member?(codes, canon), do: k end)
  end

  @doc "The current `key => codes` members map — the fold state behind resolve_key/2."
  def members(log), do: ledger(log).members

  @doc "Customer lookup by code — the robust access pattern. Returns the current record + identity block."
  # ponytail: raw-log lookup/get refold the ENTIRE log per call (ledger fold + a full History.now
  # projection) — fine at POC scale, not at catalog scale (GH #57). Callers doing many reads use
  # resolve_key(members, _) / get_projected(projection, _, _); production reads belong on the
  # api/ Postgres read models. ACT 3 of golden_record_stress.exs measures where this falls over.
  def lookup(log, code, priority) do
    case resolve_key(log, code) do
      nil -> {:not_found, Codes.canonicalize(code)}
      key -> {:ok, get(log, key, priority)}
    end
  end

  @doc "Fetch by surrogate key with its identity status (a stale key still answers, with a redirect)."
  def get(log, key, priority), do: get_projected(History.now(log, priority), log, key)

  @doc "get/3 with the `History.now/2` projection prebuilt, for callers fetching many keys."
  def get_projected(projection, log, key) do
    variant = projection |> Enum.flat_map(& &1.variants) |> Enum.find(&(&1.key == key))
    %{key: key, identity: identity_status(log, key), variant: variant}
  end

  @doc "Change feed: identity events after `cursor`, so customers can repair local copies after churn."
  def changes_since(log, cursor) do
    Enum.filter(log, fn e -> identity_event?(e) and (e.order || 0) > cursor end)
  end

  defp identity_event?(%Events.IdentityMinted{}), do: true
  defp identity_event?(%Events.IdentityMembersChanged{}), do: true
  defp identity_event?(%Events.IdentitiesMerged{}), do: true
  defp identity_event?(%Events.IdentitySplit{}), do: true
  defp identity_event?(_), do: false

  defp ledger(log), do: Enum.reduce(log, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1))
end
