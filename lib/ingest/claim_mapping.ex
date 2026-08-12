# lib/ingest/claim_mapping.ex — the medipim REFERENCE ADAPTER: envelopes → canonical claims
# (gr-beo; split onto the contract seam in gr-3jd).
#
# Stage 2 of the legacy-medipim ingest, and the adapter every future customer copies: it maps a
# source system's export (here, contract-C HistoryEnvelopes from gr-n8i) to CANONICAL CLAIMS —
# plain wire-shaped maps per docs/CLAIMS_CONTRACT.md (`canonical_claims/1`). The generic half,
# canonical claims → engine claims, lives in `CanonicalClaims` (lib/contract/canonical_claims.ex)
# and is shared with the Product API's live path. `build/1` composes both stages and yields the
# engine's claim log + the `shared` code set, ready for clustering/reconcile (gr-chq:
# `Cluster.variants(Substrate.current(claims), shared)` then `IdentityLedger.decide`).
#
# Being a BACKFILL adapter, its canonical claims carry contract-C unix-second temporal fields and
# `member_of` claims — both deliberately beyond the live wire (see CanonicalClaims' header), so
# build/1 uses the trusted `CanonicalClaims.to_engine!/1` rather than the validating seam.
#
# What the mapping does, per the design (docs/plans/2026-06-05-legacy-history-ingest-design.md):
#
#   1. FOLD per listing = (legacy_entity, source). Replay that source's granular identity events
#      (set/add/remove/delete, in recorded_at order) into a final code-set — a SNAPSHOT (v1).
#      `set` replaces a single-valued scheme (a null value clears it); `add`/`remove` edit a
#      collection; `delete` (op-4) drops the whole scheme entry. Folding runs on medipim's own
#      scheme names so eanGtin13(set) and ean(add) don't interfere, THEN maps to engine schemes.
#
#   2. CANONICALIZE + PARTITION. Every code goes through `Codes.canonicalize` (GTIN family →
#      GTIN-14). Codes that must never bridge two products — restricted/in-store GTINs
#      (`Codes.restricted?`) and non-bridging schemes (MPN/supplier ref) — are collected into the
#      `shared` set the clusterer carries but never fuses on.
#
#   3. BUILD canonical claims (wire-shaped maps; `CanonicalClaims.to_engine!/1` then builds the
#      engine claims via `Substrate.claim/5`, which re-canonicalizes idempotently):
#      * identity  — one per listing: %{"ref" => "entity:source", "codes" => <folded set>}.
#      * grouping  — synthesized, one per (listing, code): %{"code", "product" => legacy_entity}.
#                    Makes the legacy entity a first-class product label for collision reasoning.
#      * attribute — one per attribute event, anchored to the listing's primary code
#                    (CNK ▸ canonical GTIN ▸ first). Survivorship is the engine's job, not ours.
#      * member_of — one per edge add/set, anchored likewise, pointing at the collection.
#
# NOT here: media claims (out of scope for gr-beo), survivorship/clustering (the engine owns it),
# and edge removals (a snapshot-v1 simplification — member_of unions and does not retract).

defmodule ClaimMapping do
  @moduledoc """
  The medipim reference adapter: folds contract-C `HistoryEnvelope`s into canonical claims
  (`canonical_claims/1`) and composes them into engine claims plus the `shared` code set
  (`build/1`) — the backfill seam every future source adapter copies. See the header for the
  per-listing identity fold, canonicalize/partition, and the synthesized grouping/member_of claims.
  """

  # medipim field → engine scheme atom is owned by CodeRegistry (the single source of medipim code
  # knowledge): the GTIN family all canonicalize to :gtin; each national code keeps its own atom.

  # National SHORT codes, in anchor preference order: a short national code is the most stable
  # primary (cnk for BE, cip_acl7 for FR/LU, …). Preferred over GTINs so Belgian behaviour
  # (CNK-first) is unchanged and French listings anchor on cip_acl7, not a recycled barcode.
  @national_primary [:cnk, :cip_acl7, :cefip, :pzn, :sukl, :pzn_austria, :national_code, :cn]

  # schemes that identify a *supplier's* reference, not a globally-unique product — never bridge.
  @non_bridging_schemes MapSet.new([:mpn, :supplier_ref])

  # medipim edge collections that reference FIRST-CLASS entities, not collection membership
  # (gr-kek): each referenced id becomes an identity claim in its own lane plus a typed edge
  # back to the listing's anchor code. collection => {code scheme, lane, relation}. Everything
  # else ("brands", "organizations", ATC, …) stays :member_of. Snapshot-v1 semantics, like
  # member_of: edges union and do not retract.
  @lane_collections %{
    "descriptions" => {"text_id", "description", "describes"},
    "media" => {"asset_id", "media", "depicts"}
  }

  @doc """
  Map a list of `%HistoryEnvelope{}` to `%{claims: [%Events.ClaimAsserted{}], shared: MapSet}`.
  Claims carry a chronological `order` (later recorded_at ⇒ higher order ⇒ wins survivorship).

  Two stages: `canonical_claims/1` (this adapter) then `CanonicalClaims.to_engine!/1` (the
  generic contract seam) — `to_engine!` because the backfill flavor deliberately exceeds the
  live-wire validator (member_of + unix-second temporals; see CanonicalClaims).
  """
  def build(envelopes) when is_list(envelopes) do
    folded = fold_raw(envelopes)

    %{
      claims: envelopes |> canonical(folded) |> CanonicalClaims.to_engine!() |> stamp(),
      shared: folded |> listing_codes() |> shared_codes()
    }
  end

  @doc """
  Stage (a) alone: the canonical claims this adapter derives from the envelopes — wire-shaped
  maps per docs/CLAIMS_CONTRACT.md, in emission order (identity, grouping, attribute,
  member_of), each carrying contract-C unix-second `"valid_from"`/`"recorded_at"`. This is what
  a customer's mapping script would produce and submit.
  """
  def canonical_claims(envelopes) when is_list(envelopes),
    do: canonical(envelopes, fold_raw(envelopes))

  defp canonical(envelopes, folded) do
    listing_codes = listing_codes(folded)
    entity_codes = union_by_entity(listing_codes)

    listing_primary = Map.new(listing_codes, fn {k, set} -> {k, primary(Enum.sort(set))} end)
    entity_primary = Map.new(entity_codes, fn {e, set} -> {e, primary(Enum.sort(set))} end)

    # A sourced event anchors ONLY to its own listing's primary code; if that listing folded to
    # empty (delisted), the event is skipped rather than re-homed onto another source's code.
    # Only genuinely unsourced events fall back to the entity-level primary.
    anchor = fn
      entity, nil -> Map.get(entity_primary, entity)
      entity, source -> Map.get(listing_primary, {entity, source})
    end

    # Deterministic emission order — Map/MapSet iteration order is otherwise unspecified, which
    # would let stamp/1's tie-break (and primary/1's pick among equals) drift between runs/versions.
    ordered = Enum.sort_by(listing_codes, fn {k, _set} -> k end)

    identity =
      for {{e, s} = k, set} <- ordered do
        %{
          "kind" => "identity",
          "source" => s,
          "ref" => "#{e}:#{s}",
          "codes" => set |> Enum.sort() |> Enum.map(&CanonicalClaims.code_string/1),
          "valid_from" => folded[k].last_at,
          "recorded_at" => folded[k].last_at
        }
      end

    grouping =
      for {{e, s} = k, set} <- ordered, code <- Enum.sort(set) do
        %{
          "kind" => "grouping",
          "source" => s,
          "code" => CanonicalClaims.code_string(code),
          "product" => e,
          "valid_from" => folded[k].last_at,
          "recorded_at" => folded[k].last_at
        }
      end

    attribute =
      for env <- envelopes,
          ev <- env.events,
          ev.kind == :attribute,
          a = anchor.(env.legacy_entity, ev.source),
          a != nil do
        %{
          "kind" => "attribute",
          "source" => ev.source,
          "code" => CanonicalClaims.code_string(a),
          "field" => field_dim(ev),
          "value" => attribute_value(ev.data.value),
          "valid_from" => ev.valid_from,
          "recorded_at" => ev.recorded_at
        }
      end

    member_of =
      for env <- envelopes,
          ev <- env.events,
          ev.kind == :edge,
          ev.op in [:set, :add],
          ev.data.value != nil,
          not Map.has_key?(@lane_collections, ev.data.collection),
          a = anchor.(env.legacy_entity, ev.source),
          a != nil do
        %{
          "kind" => "member_of",
          "source" => ev.source,
          "code" => CanonicalClaims.code_string(a),
          "collection" => ev.data.collection,
          "member" => to_string(ev.data.value),
          "valid_from" => ev.valid_from,
          "recorded_at" => ev.recorded_at
        }
      end

    lane_entities =
      envelopes
      |> lane_refs()
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.flat_map(fn {{entity, source, collection}, %{ids: ids, last: last}} ->
        {scheme, lane, relation} = Map.fetch!(@lane_collections, collection)

        case anchor.(entity, nil) do
          nil ->
            []

          a ->
            for id <- Enum.sort(ids) do
              {vf, at} = Map.fetch!(last, id)

              [
                %{
                  "kind" => "identity",
                  "source" => source,
                  "ref" => "#{collection}:#{id}",
                  "codes" => ["#{scheme}:#{id}"],
                  "entity" => lane,
                  "valid_from" => vf || at,
                  "recorded_at" => at
                },
                %{
                  "kind" => "edge",
                  "source" => source,
                  "from" => "#{scheme}:#{id}",
                  "relation" => relation,
                  "to" => CanonicalClaims.code_string(a),
                  "valid_from" => vf || at,
                  "recorded_at" => at
                }
              ]
            end
        end
      end)

    identity ++ grouping ++ attribute ++ member_of ++ List.flatten(lane_entities)
  end

  # medipim :media events reference FIRST-CLASS entities by asset id (collection "descriptions"
  # or "media"), with real add/remove churn — fold them per (entity, source, collection) exactly
  # like identity codes, so only SURVIVING references become lane records + edges (snapshot-v1;
  # a removed asset simply does not survive the fold). Source falls back to the envelope's
  # source_system — these events carry source: nil in real dumps.
  defp lane_refs(envelopes) do
    for env <- envelopes,
        ev <- env.events,
        ev.kind == :media,
        Map.has_key?(@lane_collections, ev.data.collection),
        reduce: %{} do
      acc ->
        key = {env.legacy_entity, ev.source || env.source_system, ev.data.collection}
        id = to_string(ev.data.asset)
        cur = Map.get(acc, key, %{ids: MapSet.new(), last: %{}})

        ids = if ev.op == :remove, do: MapSet.delete(cur.ids, id), else: MapSet.put(cur.ids, id)

        Map.put(acc, key, %{ids: ids, last: Map.put(cur.last, id, {ev.valid_from, ev.recorded_at})})
    end
  end

  @doc "Just the folded, canonicalized code-set per listing — `%{{entity, source} => MapSet}`."
  def listings(envelopes) when is_list(envelopes), do: envelopes |> fold_raw() |> listing_codes()

  # Per-listing canonicalized code-sets, with delisted (now-empty) listings dropped.
  defp listing_codes(folded) do
    folded
    |> Map.new(fn {k, v} -> {k, engine_codes(v.raw)} end)
    |> Enum.reject(fn {_k, set} -> MapSet.size(set) == 0 end)
    |> Map.new()
  end

  # ── fold ──────────────────────────────────────────────────────────────────

  # Replay identity events into per-listing raw code-sets, keyed by medipim scheme name.
  # Envelope events are already time-ordered, so list order is recorded_at order.
  defp fold_raw(envelopes) do
    for env <- envelopes, ev <- env.events, ev.kind == :identity, reduce: %{} do
      acc ->
        key = {env.legacy_entity, ev.source}
        cur = Map.get(acc, key, %{raw: %{}, last_at: 0})
        Map.put(acc, key, %{raw: apply_identity(cur.raw, ev), last_at: max(cur.last_at, ev.recorded_at)})
    end
  end

  @doc false
  # Shared with FinerClaims (the per-event fold) — same delta semantics, one implementation.
  def apply_identity(raw, ev) do
    scheme = ev.data.scheme
    code = ev.data.code

    case ev.op do
      :set when is_nil(code) -> Map.delete(raw, scheme)
      :set -> Map.put(raw, scheme, MapSet.new([code]))
      :add -> Map.update(raw, scheme, MapSet.new([code]), &MapSet.put(&1, code))
      :remove -> raw |> Map.update(scheme, MapSet.new(), &MapSet.delete(&1, code)) |> drop_empty(scheme)
      :delete -> Map.delete(raw, scheme)
    end
  end

  defp drop_empty(raw, scheme) do
    case Map.get(raw, scheme) do
      %MapSet{} = s -> if MapSet.size(s) == 0, do: Map.delete(raw, scheme), else: raw
      _ -> raw
    end
  end

  # raw (medipim scheme → values) → MapSet of canonicalized engine codes.
  @doc false
  # Shared with FinerClaims.
  def engine_codes(raw) do
    for {scheme, values} <- raw, v <- values, into: MapSet.new() do
      Codes.canonicalize({scheme_atom(scheme), v})
    end
  end

  # Known medipim fields map to engine atoms via the registry (the GTIN family → :gtin); an
  # unrecognised field stays the raw string (Codes.canonicalize passes it through). The registry
  # never String.to_atom/1's an unknown field — the loader does not whitelist schemes, so that
  # would be an atom-table leak.
  defp scheme_atom(scheme), do: CodeRegistry.scheme(scheme)

  # ── helpers ───────────────────────────────────────────────────────────────

  defp union_by_entity(listing_codes) do
    Enum.reduce(listing_codes, %{}, fn {{e, _s}, set}, acc ->
      Map.update(acc, e, set, &MapSet.union(&1, set))
    end)
  end

  # primary code for anchoring: a national SHORT code (in @national_primary order) ▸ non-restricted
  # canonical GTIN ▸ any GTIN ▸ a 13-digit national code (acl13/cip13) ▸ lowest code. National
  # short codes win so Belgian listings still anchor on CNK and French ones on cip_acl7 (a stable
  # id) rather than a recycled barcode.
  @doc false
  # Shared with FinerClaims — anchoring must pick the same primary in both folds.
  def primary([]), do: nil

  def primary(codes) do
    national_short(codes) ||
      Enum.find(codes, &(match?({:gtin, _}, &1) and not Codes.restricted?(&1))) ||
      Enum.find(codes, &match?({:gtin, _}, &1)) ||
      Enum.find(codes, &match?({:acl13, _}, &1)) ||
      Enum.find(codes, &match?({:cip13, _}, &1)) ||
      codes |> Enum.sort() |> List.first()
  end

  # First code whose scheme appears earliest in @national_primary (cnk ▸ cip_acl7 ▸ …).
  defp national_short(codes) do
    Enum.find_value(@national_primary, fn scheme ->
      Enum.find(codes, &match?({^scheme, _}, &1))
    end)
  end

  # medipim emits allowedSpecies both as "human" and as ["human"]. A one-element list carries no
  # more information than its element, so the two spellings become one value and stop looking like
  # a contradiction to survivorship. Longer lists are left alone — none occur in the fixtures, and
  # the right shape for a genuine multi-value field (several claims? member_of?) is undecided.
  # See docs/CLAIM_MAPPING_SPEC.md.
  defp attribute_value([single]), do: single
  defp attribute_value(value), do: value

  @doc false
  # Shared with FinerClaims.
  def field_dim(ev) do
    case ev.data.locale do
      nil -> ev.data.field
      locale -> "#{ev.data.field}:#{locale}"
    end
  end

  defp shared_codes(listing_codes) do
    for {_k, set} <- listing_codes, code <- set, shared?(code), into: MapSet.new(), do: code
  end

  @doc false
  # Shared with FinerClaims — both folds must agree on what may never bridge.
  def shared?({scheme, _} = code),
    do: Codes.restricted?(code) or MapSet.member?(@non_bridging_schemes, scheme)

  # chronological order: later recorded_at ⇒ higher order. Stable on the original emission index.
  defp stamp(claims) do
    claims
    |> Enum.with_index()
    |> Enum.sort_by(fn {c, i} -> {c.recorded_at, i} end)
    |> Enum.with_index()
    |> Enum.map(fn {{c, _i}, order} -> %{c | order: order} end)
  end
end
