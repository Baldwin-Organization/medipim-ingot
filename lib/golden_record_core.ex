# lib/golden_record_core.ex — the DDD + event-sourced engine (compiled by Mix; no demo, no run).
#
# Contexts: Ingestion (Substrate) · Identity Resolution (Cluster + IdentityLedger) ·
#           Stewardship · Catalog (read) · History (time-travel/lineage)
#
# Beyond the base model it supports SHARED CODES: a steward can declare a (scheme, code) to be
# legitimately shared across products (e.g. a GTIN on both a bundle and its unit). A shared code
# is carried on every variant that bears it but NEVER bridges them during clustering/matching —
# that is how "two sources use the same id, but they are two products" reaches a clean end state.

defmodule Events do
  defmodule ClaimAsserted do
    @enforce_keys [:source, :kind, :data, :valid_from, :recorded_at]
    defstruct [
      :source,
      :kind,
      :data,
      :valid_from,
      :valid_to,
      :recorded_at,
      :order,
      :record_ref,
      :record_revision
    ]
  end

  defmodule SourceRecordRevised do
    @enforce_keys [
      :source,
      :ref,
      :revision,
      :operation,
      :active,
      :claims,
      :fingerprint,
      :valid_from,
      :valid_to,
      :recorded_at
    ]
    defstruct [
      :source,
      :ref,
      :revision,
      :base_revision,
      :operation,
      :active,
      :claims,
      :fingerprint,
      :valid_from,
      :valid_to,
      :recorded_at,
      :order
    ]
  end

  defmodule SourceRecordKeyBound do
    @enforce_keys [:source, :ref, :lane, :key, :recorded_at]
    defstruct [:source, :ref, :lane, :key, :valid_from, :valid_to, :recorded_at, :order]
  end

  defmodule IdentityMinted do
    @enforce_keys [:key, :codes, :recorded_at]
    defstruct [:key, :codes, :valid_from, :valid_to, :recorded_at, :order]
  end

  defmodule IdentityMembersChanged do
    @enforce_keys [:key, :codes, :recorded_at]
    defstruct [:key, :codes, :valid_from, :valid_to, :recorded_at, :order]
  end

  defmodule IdentitiesMerged do
    @enforce_keys [:from, :into, :recorded_at]
    defstruct [:from, :into, :valid_from, :valid_to, :recorded_at, :order]
  end

  defmodule IdentitySplit do
    @enforce_keys [:key, :kept_codes, :into, :recorded_at]
    defstruct [:key, :kept_codes, :into, :valid_from, :valid_to, :recorded_at, :order]
  end

  # The bookend of IdentityMinted: a key whose EVERY contributing listing was retracted (identity
  # claim with codes: []) vanishes from the members map. `codes` carries the codes the key HELD
  # before retraction — the notification payload ("SK_3 with cnk:333 was retracted").
  defmodule IdentityRetracted do
    @enforce_keys [:key, :codes, :recorded_at]
    defstruct [:key, :codes, :valid_from, :valid_to, :recorded_at, :order]
  end

  # External-id continuity: `key` answers to `legacy_id` (a consumer-facing id from a system the
  # engine replaces). Assignment is an EVENT so the mapping is auditable and replayable; resolution
  # across merges/splits is a fold (see the ingest's LegacyIds).
  defmodule LegacyIdAssigned do
    @enforce_keys [:key, :legacy_id, :recorded_at]
    defstruct [:key, :legacy_id, :valid_from, :valid_to, :recorded_at, :order]
  end

  # subject: {:attr, key, field} | {:merge, [keys]} | {:collision, key} | {:code, {scheme, code}}
  #        | {:split, key}
  defmodule ConflictFlagged do
    @enforce_keys [:subject, :candidates, :recorded_at]
    defstruct [:subject, :candidates, :valid_from, :valid_to, :recorded_at, :order]
  end

  # Four-eyes on merges: one steward ENDORSES a flagged merge of established keys; nothing fuses
  # until a SECOND, different steward approves. The endorsement is an event so the pending
  # proposal is replayable state, not UI memory.
  defmodule MergeProposed do
    @enforce_keys [:keys, :by, :recorded_at]
    defstruct [:keys, :by, :reason, :valid_from, :valid_to, :recorded_at, :order]
  end

  # decision: {:pick, value} | :rejected | :approved | :shared
  # `reason` is the steward's optional free-text justification, kept in the log.
  defmodule ConflictResolved do
    @enforce_keys [:subject, :decision, :by, :recorded_at]
    defstruct [:subject, :decision, :by, :reason, :valid_from, :valid_to, :recorded_at, :order]
  end

  defmodule ReviewCaseOpened do
    @enforce_keys [
      :case_id,
      :subject,
      :evidence,
      :evidence_digest,
      :evidence_offset,
      :required_approvals,
      :recorded_at
    ]
    defstruct [
      :case_id,
      :subject,
      :evidence,
      :evidence_digest,
      :evidence_offset,
      :required_approvals,
      :recorded_at,
      :order
    ]
  end

  defmodule ReviewCaseEndorsed do
    @enforce_keys [:case_id, :principal, :evidence_offset, :recorded_at]
    defstruct [:case_id, :principal, :evidence_offset, :proposal, :reason, :recorded_at, :order]
  end
end

defmodule Codes do
  @moduledoc """
  Code normalization & validation. The GTIN family (EAN-8 / UPC-12 / EAN-13 / GTIN-14) is ONE
  scheme at different widths: canonicalize to a 14-digit, zero-filled GTIN so equal trade items
  compare equal. Conservative — non-GTIN schemes and non-GTIN-length values pass through
  untouched, so it is safe to run over every ingested code.
  """
  @gtin_schemes [:gtin, :ean, :upc]

  # National short codes that medipim zero-pads to a fixed width. canonicalize left-pads an
  # all-digit value to the scheme's width so a query for "44813" matches a stored "0044813".
  # Real medipim data is already full-width, so padding is a no-op there.
  #
  # :cnk is DELIBERATELY EXCLUDED — real medipim cnk is always 7 digits (padding would be a no-op),
  # and ~10 existing tests use short fake cnk values ({:cnk,"0111"}/"0222"/"9"/"100"/"111"/"222"/
  # "555") that padding to 7 would silently break. (The design doc listed cnk:7; this exclusion is
  # a refinement after pre-dispatch verification.) Trim-only schemes (acl13, cip13, ndc, pdk, …)
  # are not listed — the default clause below trims them and that is all they need.
  @pad %{
    cip_acl7: 7,
    pzn: 8,
    pzn_austria: 7,
    sukl: 7,
    cefip: 7,
    national_code: 7,
    cn: 6
  }

  @doc "Canonical (scheme, value) for matching. GTIN family -> {:gtin, 14-digit zero-filled}."
  def canonicalize({scheme, value}) when scheme in @gtin_schemes do
    v = String.trim(value)
    if gtinish?(v), do: {:gtin, String.pad_leading(v, 14, "0")}, else: {scheme, v}
  end

  def canonicalize({scheme, value}) when is_map_key(@pad, scheme) do
    v = String.trim(value)
    width = Map.fetch!(@pad, scheme)

    if all_digits?(v) and String.length(v) < width,
      do: {scheme, String.pad_leading(v, width, "0")},
      else: {scheme, v}
  end

  def canonicalize({scheme, value}), do: {scheme, String.trim(value)}

  @doc "Do two codes denote the same thing once canonicalized? (8 vs zero-padded-12 vs 13 all equal)"
  def same?(a, b), do: canonicalize(a) == canonicalize(b)

  @doc "Mod-10 check-digit validity for a GTIN-family code."
  def valid_gtin?(code) do
    case canonicalize(code) do
      {:gtin, v} when byte_size(v) == 14 ->
        String.last(v) == Integer.to_string(check_digit(String.slice(v, 0, 13)))

      _ ->
        false
    end
  end

  @doc "GTIN-14 indicator digit: 0 = base unit, 1-8 = packaging levels, 9 = variable measure."
  def indicator(code) do
    case canonicalize(code) do
      {:gtin, v} when byte_size(v) == 14 -> v |> String.first() |> String.to_integer()
      _ -> nil
    end
  end

  @doc "Restricted-distribution / in-store GTIN (GS1 prefix 02 or 20-29) — NOT globally unique."
  def restricted?(code) do
    case canonicalize(code) do
      {:gtin, v} when byte_size(v) == 14 ->
        prefix = String.slice(v, 1, 2)
        prefix == "02" or (prefix >= "20" and prefix <= "29")

      _ ->
        false
    end
  end

  defp gtinish?(v), do: v =~ ~r/^\d+$/ and String.length(v) in [8, 12, 13, 14]

  defp all_digits?(v), do: v != "" and v =~ ~r/^\d+$/

  defp check_digit(payload) do
    sum =
      payload
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc -> acc + d * if(rem(i, 2) == 0, do: 3, else: 1) end)

    rem(10 - rem(sum, 10), 10)
  end
end

defmodule Lanes do
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
    asset_id: :media
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

defmodule Relations do
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

  @doc """
  Product-page description traversal (gr-sw0) — the named, bounded rules: descriptions tagged
  directly to the product (one hop), plus descriptions tagged to any substance the product
  contains (two hops, via :contains).
  """
  def product_descriptions, do: [direct: :describes, via: {:contains, :describes}]
end

defmodule Uuid do
  @moduledoc """
  Engine-minted identity (gr-2a8): a record born without a source code — a steward-created
  description, an uploaded asset — gets a `{:uuid, v4}` identity code. The scheme is shared
  across lanes, so such a claim must carry an explicit `entity:` (see `Lanes.of_claim/1`).
  """

  def mint, do: {:uuid, v4()}

  def v4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<u0::32, u1::16, u2::16, u3::16, u4::48>> = <<a::48, 4::4, b::12, 2::2, c::62>>

    :io_lib.format(~c"~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [u0, u1, u2, u3, u4])
    |> IO.iodata_to_binary()
  end
end

defmodule Substrate do
  alias Events.ClaimAsserted

  # Every ingested code is canonicalized here so equivalent representations (EAN-13 vs GTIN-14,
  # UPC vs its EAN-13 form, a GTIN-8 vs its zero-padded width) collapse to one identity.
  #
  # :member_of is the legacy spelling of an :edge (gr-xde): the constructor still accepts it,
  # but the LOG holds the generalized edge — one relationship representation, one traversal.
  def claim(source, :member_of, %{member_code: m, collection: c}, valid_from, recorded_at),
    do: claim(source, :edge, %{from: m, relation: :member_of, to: c}, valid_from, recorded_at)

  def claim(source, kind, data, valid_from, recorded_at),
    do: %ClaimAsserted{
      source: source,
      kind: kind,
      data: normalize(kind, data),
      valid_from: valid_from,
      recorded_at: recorded_at
    }

  defp normalize(:identity, %{codes: codes} = d), do: %{d | codes: Enum.map(codes, &Codes.canonicalize/1)}

  defp normalize(:identity_evidence, %{left: left, right: right} = d),
    do: %{d | left: Codes.canonicalize(left), right: Codes.canonicalize(right)}

  defp normalize(:grouping, %{code: c} = d), do: %{d | code: Codes.canonicalize(c)}
  defp normalize(:attribute, %{code: c} = d), do: %{d | code: Codes.canonicalize(c)}
  defp normalize(:media, %{target: t} = d), do: %{d | target: Codes.canonicalize(t)}

  # Both edge endpoints canonicalize, so an edge addressed by EAN-13 matches a cluster holding
  # the GTIN-14 form. (:member_of claims no longer reach here — claim/5 lowers them to :edge —
  # but a previously persisted log may still carry them, so the clause stays foldable.)
  defp normalize(:edge, %{from: f, to: t} = d),
    do: %{d | from: Codes.canonicalize(f), to: Codes.canonicalize(t)}

  defp normalize(:member_of, %{member_code: m, collection: c} = d),
    do: %{d | member_code: Codes.canonicalize(m), collection: Codes.canonicalize(c)}

  defp normalize(_kind, d), do: d

  # Public (@doc false) so the API's fold-state can maintain the current view INCREMENTALLY —
  # one Map.put per claim instead of re-grouping the whole log per projection.
  @doc false
  def slot(%ClaimAsserted{source: s, record_ref: ref} = claim) when not is_nil(ref),
    do: {s, :record, ref, local_slot(claim)}

  def slot(%ClaimAsserted{source: s, kind: :identity, data: %{ref: r}}), do: {s, :identity, r}

  def slot(%ClaimAsserted{source: s, kind: :identity_evidence, data: %{left: left, right: right}}),
    do: {s, :identity_evidence, left, right}

  def slot(%ClaimAsserted{source: s, kind: :grouping, data: %{code: c}}), do: {s, :grouping, c}
  def slot(%ClaimAsserted{source: s, kind: :attribute, data: %{code: c, field: f}}), do: {s, :attr, c, f}
  def slot(%ClaimAsserted{source: s, kind: :media, data: %{asset: a, target: t}}), do: {s, :media, a, t}

  def slot(%ClaimAsserted{source: s, kind: :edge, data: %{from: f, relation: r, to: t}}),
    do: {s, :edge, f, r, t}

  def slot(%ClaimAsserted{source: s, kind: :member_of, data: %{member_code: m, collection: c}}),
    do: {s, :member_of, m, c}

  @doc false
  def local_slot(%ClaimAsserted{kind: :identity}), do: :identity

  def local_slot(%ClaimAsserted{kind: :identity_evidence, data: %{left: left, right: right}}),
    do: {:identity_evidence, left, right}

  def local_slot(%ClaimAsserted{kind: :grouping, data: %{code: c}}), do: {:grouping, c}
  def local_slot(%ClaimAsserted{kind: :attribute, data: %{code: c, field: f}}), do: {:attr, c, f}
  def local_slot(%ClaimAsserted{kind: :media, data: %{asset: a, target: t}}), do: {:media, a, t}

  def local_slot(%ClaimAsserted{kind: :edge, data: %{from: f, relation: r, to: t}}),
    do: {:edge, f, r, t}

  def local_slot(%ClaimAsserted{kind: :member_of, data: %{member_code: m, collection: c}}),
    do: {:member_of, m, c}

  def current(claims) do
    claims
    |> Enum.group_by(&slot/1)
    |> Enum.map(fn {_slot, cs} -> Enum.max_by(cs, & &1.order) end)
  end
end

defmodule Priority do
  @enforce_keys [:table, :default]
  defstruct [:table, :default]

  def new(table, default), do: %__MODULE__{table: table, default: default}

  def rank(%__MODULE__{table: table, default: default}, dimension, source) do
    tiers = Map.get(table, dimension, default)
    Enum.find_index(tiers, fn tier -> source in tier end) || :infinity
  end
end

defmodule Survivorship do
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

defmodule Cluster do
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
      unique_scheme? = Keyword.get(opts, :unique_scheme?, &CodeRegistry.national_grade?/1)
      barcode_scheme? = Keyword.get(opts, :barcode_scheme?, &CodeRegistry.barcode_grade?/1)
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

defmodule IdentityLedger do
  @enforce_keys [:members, :next]
  defstruct [:members, :next, prefix: "SK", next_by_prefix: %{}]

  # The prefix is the lane qualifier (gr-2a8): :product ledgers keep the legacy "SK", other
  # lanes mint under their own prefix ("SUB_1", "DSC_1", …) — see Lanes.prefix/1.
  def new(prefix \\ "SK"),
    do: %__MODULE__{members: %{}, next: 1, prefix: prefix, next_by_prefix: %{prefix => 1}}

  def decide(state, {:reconcile, clusters, at}), do: decide(state, {:reconcile, clusters, MapSet.new(), at})

  def decide(state, {:reconcile, clusters, shared, at}),
    do: decide(state, {:reconcile, clusters, shared, %{}, at})

  def decide(
        %__MODULE__{members: members, next: next, prefix: prefix},
        {:reconcile, clusters, shared, preferred, at}
      ) do
    members
    |> reconcile(next, prefix, clusters, shared, preferred)
    |> then(&build_events(members, &1, at))
  end

  def evolve(%__MODULE__{} = s, %Events.IdentityMinted{key: k, codes: c}),
    do: advance(%{s | members: Map.put(s.members, k, c)}, k)

  def evolve(%__MODULE__{} = s, %Events.IdentityMembersChanged{key: k, codes: c}),
    do: advance(%{s | members: Map.put(s.members, k, c)}, k)

  def evolve(%__MODULE__{} = s, %Events.IdentitiesMerged{from: from, into: into}),
    do: %{s | members: Map.drop(s.members, from -- [into])}

  def evolve(%__MODULE__{} = s, %Events.IdentitySplit{key: k, kept_codes: kept, into: into}) do
    members = Enum.reduce(into, Map.put(s.members, k, kept), fn {nk, c}, m -> Map.put(m, nk, c) end)
    Enum.reduce(into, %{s | members: members}, fn {nk, _}, state -> advance(state, nk) end)
  end

  def evolve(%__MODULE__{} = s, %Events.IdentityRetracted{key: k}),
    do: %{s | members: Map.delete(s.members, k)}

  def evolve(%__MODULE__{} = s, %Events.ConflictFlagged{}), do: s
  def evolve(%__MODULE__{} = s, %Events.MergeProposed{}), do: s
  def evolve(%__MODULE__{} = s, %Events.ConflictResolved{}), do: s
  def evolve(%__MODULE__{} = s, %Events.ClaimAsserted{}), do: s
  def evolve(%__MODULE__{} = s, %Events.SourceRecordRevised{}), do: s
  def evolve(%__MODULE__{} = s, %Events.SourceRecordKeyBound{}), do: s
  def evolve(%__MODULE__{} = s, %Events.ReviewCaseOpened{}), do: s
  def evolve(%__MODULE__{} = s, %Events.ReviewCaseEndorsed{}), do: s
  def evolve(%__MODULE__{} = s, %Events.LegacyIdAssigned{}), do: s

  defp reconcile(old_members, next, prefix, clusters, shared, preferred) do
    original = old_members
    conflicts = cluster_conflicts(clusters, shared)
    non_bridging = MapSet.union(shared, MapSet.new(conflicts, &elem(&1, 0)))
    bare_index = bare_code_index(original, non_bridging)

    {assigns, members, next, minted, reactivated, proposals} =
      Enum.reduce(clusters, {[], old_members, next, [], [], []}, fn cluster,
                                                                    {assigns, m, n, minted, reactivated,
                                                                     proposals} ->
        candidates =
          (overlapping_keys(bare_index, cluster, non_bridging) ++ Map.get(preferred, cluster, []))
          |> Enum.uniq()
          |> Enum.sort()

        case candidates do
          [] ->
            key = "#{prefix}_#{n}"

            {[{cluster, key} | assigns], Map.put(m, key, cluster), n + 1, [key | minted], reactivated,
             proposals}

          [key] ->
            reactivated = if Map.has_key?(original, key), do: reactivated, else: [key | reactivated]

            {[{cluster, key} | assigns], Map.put(m, key, cluster), n, minted, reactivated, proposals}

          many ->
            # GATED: never auto-merge established keys — propose for steward review.
            {assigns, m, n, minted, reactivated, [{Enum.sort(many), cluster} | proposals]}
        end
      end)

    {members, _next, split} =
      assigns
      |> Enum.group_by(fn {_c, key} -> key end)
      |> Enum.reduce({members, next, []}, fn
        {_key, [_single]}, acc ->
          acc

        {key, multiple}, {m, n, split} ->
          prior = Map.get(original, key, MapSet.new())

          # Sorting first makes the tie-break total: Enum.max_by keeps the FIRST maximum, so
          # equal-ranked clusters resolve to the lowest code signature whatever order they arrived in.
          {keep_cluster, _} =
            multiple
            |> Enum.sort_by(fn {c, _} -> Enum.sort(c) end)
            |> Enum.max_by(fn {c, _} -> keeper_rank(c, prior) end)

          {into, m, n} =
            multiple
            |> Enum.map(&elem(&1, 0))
            |> List.delete(keep_cluster)
            |> Enum.reduce({[], m, n}, fn c, {ks, m, n} ->
              {[{"#{prefix}_#{n}", c} | ks], Map.put(m, "#{prefix}_#{n}", c), n + 1}
            end)

          {Map.put(m, key, keep_cluster), n, [{key, Enum.reverse(into)} | split]}
      end)

    # Reversed so that on a duplicate cluster the most recent assignment wins, exactly as the
    # Enum.find_value scan over the prepend-built list did.
    assigns_by_cluster = assigns |> Enum.reverse() |> Map.new()

    held_proposals =
      conflicts
      |> Enum.flat_map(fn {_code, carriers} ->
        keys =
          carriers
          |> Enum.map(&Map.get(assigns_by_cluster, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.sort()

        if length(keys) > 1 do
          [{keys, Enum.reduce(carriers, &MapSet.union/2)}]
        else
          []
        end
      end)
      |> Enum.uniq_by(&elem(&1, 0))

    proposals = Enum.reverse(proposals) ++ held_proposals
    assigned_keys = MapSet.new(assigns, fn {_cluster, key} -> key end)
    proposed_keys = for {keys, _cluster} <- proposals, key <- keys, into: MapSet.new(), do: key
    touched = MapSet.union(assigned_keys, proposed_keys)
    retracted = for {key, _} <- original, not MapSet.member?(touched, key), do: key
    live = Map.drop(members, retracted)

    %{
      minted: Enum.reverse(minted),
      reactivated: Enum.reverse(reactivated),
      split: Enum.reverse(split),
      proposals: proposals,
      conflicts: conflicts,
      swaps: national_swaps(original, live),
      retracted: Enum.sort(retracted),
      members: live
    }
  end

  # An established key that LOSES a national code has changed what it denotes, even though it
  # survived reconciliation. Gaining one is an alias and stays quiet; losing one is the signature
  # of a barcode transfer or a mis-keyed upstream record, and a person should see it.
  defp national_swaps(original, live) do
    original
    |> Enum.flat_map(fn {key, prior} ->
      case Map.fetch(live, key) do
        :error ->
          []

        {:ok, now} ->
          lost = MapSet.difference(national_codes(prior), national_codes(now))
          if MapSet.size(lost) == 0, do: [], else: [{key, Enum.sort(lost), Enum.sort(now)}]
      end
    end)
    |> Enum.sort()
  end

  defp build_events(old_members, outcome, at) do
    mints =
      Enum.map(outcome.minted, &%Events.IdentityMinted{key: &1, codes: outcome.members[&1], recorded_at: at})

    reactivations =
      Enum.map(outcome.reactivated, fn key ->
        %Events.IdentityMembersChanged{key: key, codes: outcome.members[key], recorded_at: at}
      end)

    splits =
      Enum.map(outcome.split, fn {key, into} ->
        %Events.IdentitySplit{
          key: key,
          kept_codes: outcome.members[key],
          into: Enum.map(into, fn {k, _} -> {k, outcome.members[k]} end),
          recorded_at: at
        }
      end)

    proposals =
      Enum.map(outcome.proposals, fn {keys, cluster} ->
        %Events.ConflictFlagged{subject: {:merge, keys}, candidates: cluster, recorded_at: at}
      end)

    identity_conflicts =
      Enum.map(outcome.conflicts, fn {code, carriers} ->
        %Events.ConflictFlagged{
          subject: {:identity_conflict, code},
          candidates: Enum.map(carriers, &Enum.sort/1),
          recorded_at: at
        }
      end)

    identity_swaps =
      Enum.map(outcome.swaps, fn {key, lost, now} ->
        %Events.ConflictFlagged{subject: {:identity_swap, key}, candidates: [lost, now], recorded_at: at}
      end)

    retractions =
      Enum.map(outcome.retracted, fn key ->
        %Events.IdentityRetracted{key: key, codes: Map.get(old_members, key, MapSet.new()), recorded_at: at}
      end)

    mints ++
      reactivations ++
      splits ++
      proposals ++
      identity_conflicts ++ identity_swaps ++ retractions ++ keeps_changed(old_members, outcome, at)
  end

  defp keeps_changed(old_members, outcome, at) do
    skip =
      MapSet.new(Enum.flat_map(outcome.split, fn {key, into} -> [key | Enum.map(into, &elem(&1, 0))] end))

    for {key, old} <- old_members,
        not MapSet.member?(skip, key),
        Map.has_key?(outcome.members, key),
        outcome.members[key] != old,
        do: %Events.IdentityMembersChanged{key: key, codes: outcome.members[key], recorded_at: at}
  end

  # Inverted index (non-shared code -> [key]) built once per reconcile, so overlapping_keys is a
  # union of lookups instead of a full members scan per cluster.
  defp bare_code_index(members, shared) do
    for {key, codes} <- members, code <- MapSet.difference(codes, shared), reduce: %{} do
      acc -> Map.update(acc, code, [key], &[key | &1])
    end
  end

  defp overlapping_keys(bare_index, cluster, shared) do
    cluster
    |> MapSet.difference(shared)
    |> Enum.flat_map(&Map.get(bare_index, &1, []))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp cluster_conflicts(clusters, shared) do
    clusters
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {cluster, index}, carriers ->
      Enum.reduce(cluster, carriers, fn code, acc ->
        if MapSet.member?(shared, code),
          do: acc,
          else: Map.update(acc, code, [{index, cluster}], &[{index, cluster} | &1])
      end)
    end)
    |> Enum.flat_map(fn {code, carriers} ->
      carriers = carriers |> Enum.uniq_by(&elem(&1, 0)) |> Enum.sort_by(&elem(&1, 0))
      if length(carriers) > 1, do: [{code, Enum.map(carriers, &elem(&1, 1))}], else: []
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc false
  # Which cluster KEEPS the key when one key's codes split across several clusters.
  #
  # The old rule was "whichever side holds a GTIN". That is backwards: a barcode is explicitly
  # reassignable — NHSBSA publishes a GTIN Transfer Tracking Log of codes moving between packs —
  # so a barcode following a product to a new pack would drag the surrogate key with it, silently
  # re-pointing every downstream reference. National codes are assigned once and never reissued,
  # so they, not the barcode, say which cluster CONTINUES what the key already meant.
  #
  # Ranked highest-first: national codes retained from the prior members, then other non-barcode
  # codes retained, then total overlap, then the cluster's own national weight (the CNK-outranks-
  # GTIN rule LegacyXref spells out) for a split with no prior overlap at all.
  def keeper_rank(cluster, prior) do
    shared = MapSet.intersection(cluster, prior)

    {grade_count(shared, :national), grade_count(shared, :none), MapSet.size(shared),
     grade_count(cluster, :national)}
  end

  defp grade_count(codes, grade),
    do: Enum.count(codes, fn {scheme, _} -> CodeRegistry.bridge_grade(scheme) == grade end)

  defp national_codes(codes),
    do: codes |> Enum.filter(fn {scheme, _} -> CodeRegistry.national_grade?(scheme) end) |> MapSet.new()

  # Works for any lane prefix ("SK_7", "SUB_3", "DSC_12" — the trailing integer is the counter).
  defp key_num(key), do: key |> String.split("_") |> List.last() |> String.to_integer()

  defp key_prefix(key), do: key |> String.split("_") |> Enum.drop(-1) |> Enum.join("_")

  defp advance(%__MODULE__{} = s, key) do
    next = key_num(key) + 1
    prefix = key_prefix(key)

    %{
      s
      | next: max(s.next, next),
        next_by_prefix: Map.update(Map.get(s, :next_by_prefix, %{}), prefix, next, &max(&1, next))
    }
  end
end

defmodule Stewardship do
  @doc "Flag every attribute priority cannot settle (a tie at the top tier)."
  def detect(members, live_claims, priority, at) do
    attrs = Enum.filter(live_claims, &(&1.kind == :attribute))

    for {key, codes} <- members,
        {field, decision} <- Survivorship.field_decisions(codes, attrs, priority),
        decision.status == :needs_review do
      %Events.ConflictFlagged{subject: {:attr, key, field}, candidates: decision.candidates, recorded_at: at}
    end
  end

  @doc """
  Flag a SOURCE WITHDRAWAL: a source retracted its listing (codes: []) but the key survives
  under other sources. The steward needs visibility — the product lost evidence.
  """
  def detect_withdrawals(old_live, new_live, members, at) do
    # code -> [key] built once; a held conflict can put one code in several keys' sets.
    keys_by_code =
      for {key, codes} <- members, code <- codes, reduce: %{} do
        acc -> Map.update(acc, code, [key], &[key | &1])
      end

    old_sources = sources_per_key(old_live, keys_by_code)
    new_sources = sources_per_key(new_live, keys_by_code)

    for {key, _codes} <- members,
        old = Map.get(old_sources, key, MapSet.new()),
        new = Map.get(new_sources, key, MapSet.new()),
        lost = MapSet.difference(old, new),
        MapSet.size(lost) > 0 do
      %Events.ConflictFlagged{
        subject: {:source_withdrew, key},
        candidates: Enum.map(lost, &%{source: &1}),
        recorded_at: at
      }
    end
  end

  defp sources_per_key(live_claims, keys_by_code) do
    for claim <- live_claims,
        claim.kind == :identity,
        claim.data.codes != [],
        key <- claim.data.codes |> Enum.flat_map(&Map.get(keys_by_code, &1, [])) |> Enum.uniq(),
        reduce: %{} do
      acc -> Map.update(acc, key, MapSet.new([claim.source]), &MapSet.put(&1, claim.source))
    end
  end

  @doc "Flag a CODE COLLISION: one variant whose grouping claims point at >1 distinct product."
  def detect_collisions(members, live_claims, at) do
    groups = Enum.filter(live_claims, &(&1.kind == :grouping))

    for {key, codes} <- members,
        prods = products_of(codes, groups),
        length(Enum.uniq(Enum.map(prods, & &1.product))) > 1 do
      %Events.ConflictFlagged{subject: {:collision, key}, candidates: prods, recorded_at: at}
    end
  end

  defp products_of(codes, groups) do
    groups
    |> Enum.filter(&MapSet.member?(codes, &1.data.code))
    |> Enum.map(&%{source: &1.source, product: &1.data.product})
  end

  def resolve_attribute(key, field, value, by, at, reason \\ nil),
    do: [
      %Events.ConflictResolved{
        subject: {:attr, key, field},
        decision: {:pick, value},
        by: by,
        reason: reason,
        recorded_at: at
      }
    ]

  def reject_merge(keys, by, at, reason \\ nil),
    do: [
      %Events.ConflictResolved{
        subject: {:merge, Enum.sort(keys)},
        decision: :rejected,
        by: by,
        reason: reason,
        recorded_at: at
      }
    ]

  def mark_shared(scheme_code, by, at),
    do: [%Events.ConflictResolved{subject: {:code, scheme_code}, decision: :shared, by: by, recorded_at: at}]

  @doc "Steward verdict on a code collision: this variant truly belongs to ONE product."
  def resolve_collision(key, product, by, at),
    do: [
      %Events.ConflictResolved{
        subject: {:collision, key},
        decision: {:product, product},
        by: by,
        recorded_at: at
      }
    ]

  @doc """
  Endorse a merge proposal — the four-eyes gate. Merging ESTABLISHED keys needs two distinct
  stewards: the first endorsement records a `MergeProposed`, the second (by a DIFFERENT steward)
  fuses via `approve_merge/5`. The same steward endorsing twice is refused HERE, by the decision
  function — no router or UI gets a say. `pending` is the open proposal (anything with a `:by`,
  e.g. the folded `MergeProposed`) or `nil`.
  """
  def endorse_merge(members, keys, pending, by, at, reason \\ nil)

  def endorse_merge(_members, keys, nil, by, at, reason),
    do: {:proposed, propose_merge(keys, by, at, reason)}

  def endorse_merge(_members, _keys, %{by: proposer}, by, _at, _reason) when proposer == by,
    do: {:error, :four_eyes}

  def endorse_merge(members, keys, %{by: _other}, by, at, reason),
    do: {:ok, approve_merge(members, keys, by, at, reason)}

  @doc "The first of the four eyes: record a steward's endorsement of a merge, fusing nothing."
  def propose_merge(keys, by, at, reason \\ nil),
    do: [%Events.MergeProposed{keys: Enum.sort(keys), by: by, reason: reason, recorded_at: at}]

  @doc "The raw fuse — emits the merge events. The steward surface reaches it via `endorse_merge/6`."
  def approve_merge(members, keys, by, at, reason \\ nil) do
    keys = Enum.sort(keys)
    [survivor | _] = keys
    union = keys |> Enum.map(&Map.get(members, &1, MapSet.new())) |> Enum.reduce(&MapSet.union/2)

    standing_same_evidence =
      for {left_key, index} <- Enum.with_index(keys),
          right_key <- Enum.drop(keys, index + 1),
          {scheme, _} = left <- Map.get(members, left_key, MapSet.new()),
          {^scheme, _} = right <- Map.get(members, right_key, MapSet.new()),
          left != right,
          CodeRegistry.national_grade?(scheme),
          uniq: true do
        Substrate.claim(
          :steward,
          :identity_evidence,
          %{relation: :same, left: left, right: right, by: by, reason: reason},
          at,
          at
        )
      end

    standing_same_evidence ++
      [
        %Events.IdentitiesMerged{from: keys, into: survivor, recorded_at: at},
        %Events.IdentityMembersChanged{key: survivor, codes: union, recorded_at: at},
        %Events.ConflictResolved{
          subject: {:merge, keys},
          decision: :approved,
          by: by,
          reason: reason,
          recorded_at: at
        }
      ]
  end

  @doc """
  Suppress one derived description↔product pairing (gr-745) — four-eyes, exactly like merges:
  the first steward endorsement records a proposal, a second DISTINCT steward emits the steward
  suppress edge. The suppression is an ordinary `:edge` claim (source `:steward`, relation
  `:suppress`, description code → product code), so it is retractable, bitemporal, visible in
  history, and re-homes on splits like every other edge. It hides the description on THAT
  product only — the substance tag stays intact. `pending` is the open proposal or `nil`
  (see `pending_suppress/3`).
  """
  def endorse_suppress(from, to, pending, by, at, reason \\ nil)

  def endorse_suppress(from, to, nil, by, at, reason),
    do:
      {:proposed,
       [%Events.MergeProposed{keys: [suppress_subject(from, to)], by: by, reason: reason, recorded_at: at}]}

  def endorse_suppress(_from, _to, %{by: proposer}, by, _at, _reason) when proposer == by,
    do: {:error, :four_eyes}

  def endorse_suppress(from, to, %{by: _other}, by, at, reason) do
    {:ok,
     [
       Substrate.claim(:steward, :edge, %{from: from, relation: :suppress, to: to}, at, at),
       %Events.ConflictResolved{
         subject: suppress_subject(from, to),
         decision: :approved,
         by: by,
         reason: reason,
         recorded_at: at
       }
     ]}
  end

  @doc "The open suppress proposal for this description↔product pairing, or nil (decided/none)."
  def pending_suppress(log, from, to) do
    subject = suppress_subject(from, to)

    if Enum.any?(log, &match?(%Events.ConflictResolved{subject: ^subject}, &1)),
      do: nil,
      else: Enum.find(log, &match?(%Events.MergeProposed{keys: [^subject]}, &1))
  end

  defp suppress_subject(from, to), do: {:suppress, Codes.canonicalize(from), Codes.canonicalize(to)}

  @doc """
  Steward-initiated split: carve groups of codes out of `key` into freshly minted keys; whatever
  remains stays with the original key. Mirrors `approve_merge/4`, but takes the ledger — minting
  the carved-out keys needs its `next` counter. Carve-out codes are canonicalized and clipped to
  the codes the key actually owns. The decision event records WHO split (`IdentitySplit` has no
  `by` field), so the steward survives in the lineage.
  """
  def split(
        %IdentityLedger{members: members, next: next, prefix: prefix},
        key,
        carve_outs,
        by,
        at,
        reason \\ nil
      ) do
    owned = Map.get(members, key, MapSet.new())

    {into, _} =
      Enum.map_reduce(carve_outs, next, fn codes, n ->
        carved = codes |> MapSet.new(&Codes.canonicalize/1) |> MapSet.intersection(owned)
        {{"#{prefix}_#{n}", carved}, n + 1}
      end)

    kept = Enum.reduce(into, owned, fn {_k, codes}, acc -> MapSet.difference(acc, codes) end)

    [
      %Events.IdentitySplit{key: key, kept_codes: kept, into: into, recorded_at: at},
      %Events.ConflictResolved{
        subject: {:split, key},
        decision: :approved,
        by: by,
        reason: reason,
        recorded_at: at
      }
    ]
  end

  @doc "Codes a steward has declared legitimately shared (read from the log)."
  def shared_codes(log) do
    for %Events.ConflictResolved{subject: {:code, c}, decision: :shared} <- log, into: MapSet.new(), do: c
  end

  @doc "Pair each flagged conflict with its verdict (or nil if still open)."
  def queue(log) do
    resolved = for %Events.ConflictResolved{} = e <- log, into: %{}, do: {e.subject, e}
    for %Events.ConflictFlagged{} = f <- log, do: {f, Map.get(resolved, f.subject)}
  end
end

defmodule Catalog do
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

  # The derived description set (gr-sw0): descriptions tagged directly to this variant, plus
  # descriptions tagged to any substance it contains — Relations.product_descriptions/0 is the
  # named traversal, never blanket closure. Each entry carries its provenance (`via` — WHY it is
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

defmodule History do
  @doc """
  Project what was known at `known_at` about the world on `effective_at`.

  Selection happens before identity reconciliation: future or bounded revisions cannot hide the
  prior applicable record, and a late correction changes only queries made after it was recorded.
  Effective intervals are half-open: `valid_from <= date < valid_to`.
  """
  def project_bitemporal(log, known_at, effective_at, priority) do
    state = state_bitemporal(log, known_at, effective_at)
    Catalog.project(state.members, state.claims, priority, state.overrides)
  end

  @doc false
  def state_bitemporal(log, known_at, %Date{} = effective_at) do
    known = Enum.filter(log, &Bitemporal.known?(&1, known_at))

    if Enum.any?(known, &match?(%Events.SourceRecordRevised{}, &1)) do
      source_record_state(known, effective_at)
    else
      legacy_state(known, effective_at)
    end
  end

  defp source_record_state(known, effective_at) do
    boundaries =
      known
      |> Enum.flat_map(fn event ->
        [Map.get(event, :valid_from), Map.get(event, :valid_to)]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn
        %Date{} = date -> date
        other -> Bitemporal.effective_date(other)
      end)
      |> Enum.filter(&(Date.compare(&1, effective_at) != :gt))
      |> Kernel.++([effective_at])
      |> Enum.uniq()
      |> Enum.sort(Date)

    # Boundary-invariant event lists, extracted once instead of refiltered per boundary.
    revisions = Enum.filter(known, &match?(%Events.SourceRecordRevised{}, &1))
    merges = Enum.filter(known, &match?(%Events.IdentitiesMerged{}, &1))
    bindings = Enum.filter(known, &match?(%Events.SourceRecordKeyBound{}, &1))

    ledger =
      Enum.reduce(boundaries, IdentityLedger.new(), fn boundary, ledger ->
        claims = claims_bitemporal_known(known, boundary)
        shared = shared(known, claims, boundary)

        # Per-lane clusters computed once per boundary, shared by preferred/ and the reconcile.
        lane_clusters =
          Map.new(Lanes.lanes(), fn lane ->
            identity = Lanes.identity_claims(claims, lane)
            evidence = Lanes.identity_evidence(claims, lane)
            {lane, Cluster.variants(identity ++ evidence, shared)}
          end)

        ledger = apply_merges(ledger, merges, boundary)

        reconcile_temporal(
          ledger,
          lane_clusters,
          preferred(revisions, merges, bindings, lane_clusters, boundary),
          shared,
          boundary
        )
      end)

    %{
      members: ledger.members,
      claims: claims_bitemporal_known(known, effective_at),
      overrides: overrides_from(Enum.filter(known, &Bitemporal.effective?(&1, effective_at)))
    }
  end

  defp legacy_state(known, effective_at) do
    applicable = Enum.filter(known, &Bitemporal.effective?(&1, effective_at))

    claims =
      applicable
      |> Enum.filter(&match?(%Events.ClaimAsserted{}, &1))
      |> Substrate.current()

    %{
      members: Enum.reduce(applicable, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1)).members,
      claims: claims,
      overrides: overrides_from(applicable)
    }
  end

  @doc false
  def claims_bitemporal(log, known_at, %Date{} = effective_at) do
    log
    |> Enum.filter(&Bitemporal.known?(&1, known_at))
    |> claims_bitemporal_known(effective_at)
  end

  defp claims_bitemporal_known(known, %Date{} = effective_at) do
    standalone =
      known
      |> Enum.filter(&match?(%Events.ClaimAsserted{}, &1))
      |> Enum.filter(&Bitemporal.effective?(&1, effective_at))
      |> Substrate.current()

    source =
      known
      |> selected_records(effective_at)
      |> Enum.flat_map(fn
        %Events.SourceRecordRevised{active: false} ->
          []

        revision ->
          Enum.map(revision.claims, fn claim ->
            %{
              claim
              | valid_from: revision.valid_from,
                valid_to: revision.valid_to,
                recorded_at: revision.recorded_at,
                order: revision.order
            }
          end)
      end)

    Substrate.current(standalone ++ source)
  end

  def project_as_of(log, date, priority), do: project_bitemporal(log, date, date, priority)

  def project_valid_as_of(log, valid_date, priority),
    do: project_bitemporal(log, DateTime.utc_now(), valid_date, priority)

  def now(log, priority), do: project_bitemporal(log, DateTime.utc_now(), Date.utc_today(), priority)

  defp selected_records(known, effective_at) do
    known
    |> Enum.filter(&match?(%Events.SourceRecordRevised{}, &1))
    |> Enum.filter(&Bitemporal.effective?(&1, effective_at))
    |> Enum.group_by(&{&1.source, &1.ref})
    |> Enum.map(fn {_record, revisions} ->
      Enum.max_by(revisions, &{Bitemporal.sort_key(&1.recorded_at), &1.order || -1})
    end)
  end

  defp reconcile_temporal(ledger, lane_clusters, preferred, shared, at) do
    {events, _ledgers} =
      Enum.flat_map_reduce(Lanes.lanes(), FinerClaims.ledgers_from(ledger), fn lane, ledgers ->
        clusters = Map.fetch!(lane_clusters, lane)
        lane_preferred = Map.take(preferred, clusters)

        events =
          IdentityLedger.decide(
            ledgers[lane],
            {:reconcile, clusters, shared, lane_preferred, at}
          )

        next = Enum.reduce(events, ledgers[lane], &IdentityLedger.evolve(&2, &1))
        {events, Map.put(ledgers, lane, next)}
      end)

    Enum.reduce(events, ledger, &IdentityLedger.evolve(&2, &1))
  end

  defp preferred(revisions, merges, bindings, lane_clusters, effective_at) do
    records =
      revisions
      |> selected_records(effective_at)
      |> Enum.filter(& &1.active)
      |> Map.new(&{{&1.source, &1.ref}, &1})

    redirects =
      for merge <- merges,
          Bitemporal.effective?(merge, effective_at),
          from <- merge.from -- [merge.into],
          into: %{},
          do: {from, merge.into}

    clusters = Enum.flat_map(Lanes.lanes(), &Map.fetch!(lane_clusters, &1))

    bindings
    |> Enum.reduce(%{}, fn binding, acc ->
      with %Events.SourceRecordRevised{} = record <- Map.get(records, {binding.source, binding.ref}),
           identity when not is_nil(identity) <- Enum.find(record.claims, &(&1.kind == :identity)),
           codes = MapSet.new(identity.data.codes),
           cluster when not is_nil(cluster) <- Enum.find(clusters, &MapSet.subset?(codes, &1)) do
        key = follow_redirect(binding.key, redirects)
        Map.update(acc, cluster, [key], &[key | &1])
      else
        _ -> acc
      end
    end)
  end

  defp shared(known, claims, effective_at) do
    declared =
      for %Events.ConflictResolved{subject: {:code, code}, decision: :shared} = decision <- known,
          Bitemporal.effective?(decision, effective_at),
          into: MapSet.new(),
          do: code

    restricted =
      for claim <- claims,
          claim.kind == :identity,
          code <- claim.data.codes,
          ClaimMapping.shared?(code),
          into: MapSet.new(),
          do: code

    MapSet.union(declared, restricted)
  end

  defp apply_merges(ledger, merges, effective_at) do
    merges
    |> Enum.filter(&Bitemporal.effective?(&1, effective_at))
    |> Enum.sort_by(&(&1.order || -1))
    |> Enum.reduce(ledger, &IdentityLedger.evolve(&2, &1))
  end

  defp follow_redirect(key, redirects) do
    case Map.get(redirects, key) do
      nil -> key
      next -> follow_redirect(next, redirects)
    end
  end

  def lineage(log, key) do
    Enum.filter(log, fn
      %Events.IdentityMinted{key: k} -> k == key
      %Events.IdentityMembersChanged{key: k} -> k == key
      %Events.IdentitiesMerged{from: from, into: into} -> key in from or into == key
      %Events.IdentitySplit{key: k, into: into} -> k == key or Enum.any?(into, fn {nk, _} -> nk == key end)
      %Events.ConflictFlagged{subject: {:merge, keys}} -> key in keys
      %Events.ConflictFlagged{subject: {:attr, k, _}} -> k == key
      %Events.ConflictFlagged{subject: {:collision, k}} -> k == key
      %Events.MergeProposed{keys: keys} -> key in keys
      %Events.ConflictResolved{subject: {:merge, keys}} -> key in keys
      %Events.ConflictResolved{subject: {:attr, k, _}} -> k == key
      %Events.ConflictResolved{subject: {:collision, k}} -> k == key
      %Events.ConflictResolved{subject: {:split, k}} -> k == key
      %Events.LegacyIdAssigned{key: k} -> k == key
      _ -> false
    end)
  end

  defp overrides_from(events) do
    resolved = for %Events.ConflictResolved{} = e <- events, do: e

    attr =
      resolved
      |> Enum.filter(&match?(%Events.ConflictResolved{subject: {:attr, _, _}, decision: {:pick, _}}, &1))
      |> Enum.group_by(fn %Events.ConflictResolved{subject: {:attr, k, d}} -> {k, d} end)
      |> Map.new(fn {k, evs} -> {k, Enum.max_by(evs, & &1.order)} end)

    product =
      resolved
      |> Enum.filter(&match?(%Events.ConflictResolved{subject: {:collision, _}, decision: {:product, _}}, &1))
      |> Enum.group_by(fn %Events.ConflictResolved{subject: {:collision, k}} -> k end)
      |> Map.new(fn {k, evs} -> {k, evs |> Enum.max_by(& &1.order) |> Map.fetch!(:decision) |> elem(1)} end)

    %{attr: attr, product: product}
  end
end

defmodule Api do
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

defmodule PublicId do
  @moduledoc """
  Identity-grade, customer-facing schemes like CNK. The surrogate key is internal; CNK is the
  public key — strictly unique, never shared. Two sources giving different CNKs for the same
  product is fine: they become canonical + alias(es) on one key, with the canonical chosen by
  priority. The customer resolves by ANY of them.
  """

  @doc "Canonical public id of `scheme` for `key` (by source priority), plus its aliases."
  def canonical(scheme, key, log, priority),
    do: do_canonical(scheme, key, ledger(log).members, fn -> identity_claims(log) end, priority)

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
  def collisions(scheme, log) when is_list(log), do: collisions(scheme, ledger(log).members)

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

  defp ledger(log), do: Enum.reduce(log, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1))
end
