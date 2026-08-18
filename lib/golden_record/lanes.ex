defmodule GoldenRecord.Lanes do
  alias GoldenRecord.{Events, Cluster, IdentityLedger}

  @moduledoc """
  Typed entity lanes (gr-2a8): every code scheme belongs to exactly one entity type, identity
  claims route to their lane, and each lane folds its own ledger with a lane-qualified surrogate
  key prefix. Cross-lane bridging is structurally impossible — the lanes are disjoint folds, not
  a validation rule. `:uuid` is the one shared scheme (engine-minted identity for records born
  without a source code, see `Uuid`); an identity claim whose codes are all lane-neutral must
  carry an explicit `entity:` in its data.
  """

  @lanes [:product, :substance, :description, :media]

  # scheme => lane. Anything not listed is :product — every pre-lane scheme (cnk, gtin, isbn, …)
  # was a product code, so the default keeps existing logs and adapters meaning what they meant.
  @lane_of %{
    cas: :substance,
    unii: :substance,
    substance_id: :substance,
    text_id: :description,
    asset_id: :media,
    leaflet_id: :media
  }

  # Lane-qualified surrogate-key prefixes. :product keeps the legacy "SK" so existing logs,
  # fixtures, and customer-facing keys are unchanged by the lanes migration.
  @prefix %{product: "SK", substance: "SUB", description: "DSC", media: "MED"}

  @by_name Map.new(@lanes, &{Atom.to_string(&1), &1})

  def lanes, do: @lanes
  def prefix(lane), do: Map.fetch!(@prefix, lane)

  @doc ~s{Lane atom for a wire entity name ("description" => :description) — never an atom leak.}
  def parse(name), do: Map.fetch(@by_name, name)

  @doc """
  Lane of one code scheme. Runtime registry declarations win; built-in schemes remain the
  compatibility fallback. `:uuid` is shared (nil); undeclared schemes default to :product.
  """
  def lane_of_scheme(scheme), do: lane_of_scheme(scheme, nil)
  def lane_of_scheme(:uuid, _registry), do: nil
  def lane_of_scheme("uuid", _registry), do: nil

  def lane_of_scheme(scheme, %SchemeRegistry{} = registry),
    do: SchemeRegistry.lane(registry, scheme) || Map.get(@lane_of, scheme, :product)

  def lane_of_scheme(scheme, nil), do: Map.get(@lane_of, scheme, :product)

  @doc "Lane of a surrogate key, by its prefix (\"SUB_3\" => :substance)."
  def lane_of_key(key) do
    Enum.find(@lanes -- [:product], :product, &String.starts_with?(key, prefix(&1) <> "_"))
  end

  @doc """
  Lane of an identity claim: the unique lane among its codes' schemes (`:uuid` is neutral),
  falling back to an explicit `entity:` in the claim data, else :product. Codes from two lanes
  in one claim are a contract violation — `{:error, {:mixed_lanes, lanes}}`.
  """
  def of_claim(claim), do: of_claim(claim, nil)

  def of_claim(%Events.ClaimAsserted{kind: :identity, data: data}, registry) do
    data.codes
    |> Enum.map(fn {scheme, _} -> lane_of_scheme(scheme, registry) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> {:ok, Map.get(data, :entity, :product)}
      [lane] -> {:ok, lane}
      lanes -> {:error, {:mixed_lanes, Enum.sort(lanes)}}
    end
  end

  @doc "The identity claims of one lane (mixed-lane claims belong to no lane)."
  def identity_claims(claims, lane), do: identity_claims(claims, lane, nil)

  def identity_claims(claims, lane, registry),
    do: Enum.filter(claims, &(&1.kind == :identity and of_claim(&1, registry) == {:ok, lane}))

  @doc false
  def identity_evidence(claims, lane, registry \\ nil) do
    Enum.filter(claims, fn
      %Events.ClaimAsserted{kind: :identity_evidence, data: %{left: {left, _}, right: {right, _}}} ->
        lane_of_scheme(left, registry) == lane and lane_of_scheme(right, registry) == lane

      _ ->
        false
    end)
  end

  @doc "Partition a ledger's members map by each key's lane."
  def partition_members(members) do
    grouped = Enum.group_by(members, fn {k, _codes} -> lane_of_key(k) end)
    Map.new(@lanes, fn lane -> {lane, Map.new(Map.get(grouped, lane, []))} end)
  end

  @doc "A fresh ledger per lane, each minting under its own prefix."
  def new_ledgers, do: Map.new(@lanes, &{&1, IdentityLedger.new(prefix(&1))})

  @doc """
  Cluster + reconcile each lane's identity claims against that lane's own ledger — the per-lane
  fold. Returns `{identity_events, ledgers}`; events come out in lane order (product first).
  """
  def reconcile(live_claims, shared, ledgers, at), do: reconcile(live_claims, shared, ledgers, at, nil)

  def reconcile(live_claims, shared, ledgers, at, registry),
    do: reconcile(live_claims, shared, ledgers, at, registry, %{})

  def reconcile(live_claims, shared, ledgers, at, registry, preferred) do
    Enum.flat_map_reduce(@lanes, ledgers, fn lane, acc ->
      case identity_claims(live_claims, lane, registry) do
        [] ->
          # A lane with NO identity claims is SKIPPED — members persist untouched. This fold
          # reads an append-only claim stream, possibly partial (a live batch may speak about
          # one lane only), so an empty lane means "no information", never "nothing exists".
          # History.reconcile_temporal deliberately does the OPPOSITE (retract): it replays a
          # complete effective snapshot, where absence IS evidence. Do not converge the two —
          # see gr-huw and test/reconcile_empty_lane_test.exs.
          {[], acc}

        claims ->
          clusters = Cluster.variants(claims ++ identity_evidence(live_claims, lane, registry), shared)
          lane_preferred = Map.take(preferred, clusters)
          events = IdentityLedger.decide(acc[lane], {:reconcile, clusters, shared, lane_preferred, at})
          {events, Map.put(acc, lane, Enum.reduce(events, acc[lane], &IdentityLedger.evolve(&2, &1)))}
      end
    end)
  end
end
