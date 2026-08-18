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

  # medipim edge collections that reference FIRST-CLASS entities, not collection membership
  # (gr-kek): each referenced id becomes an identity claim in its own lane plus a typed edge
  # back to the listing's anchor code. collection => {code scheme, lane, relation}. Everything
  # else ("brands", "organizations", ATC, …) stays :member_of. Snapshot-v1 semantics, like
  # member_of: edges union and do not retract.
  @lane_collections %{
    "descriptions" => {"text_id", "description", "describes"},
    "media" => {"asset_id", "media", "depicts"},
    # AU leaflets (gr-sx7.1): a third first-class asset collection. Own scheme — leaflet ids come
    # from a different medipim table than media ids, so sharing :asset_id would collide id-spaces.
    "leaflets" => {"leaflet_id", "media", "depicts"}
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
    periods = listing_periods(envelopes)

    %{
      claims: envelopes |> canonical(periods) |> CanonicalClaims.to_engine!() |> stamp(),
      shared: folded |> listing_codes() |> shared_codes(),
      rejected: rejected(envelopes, periods)
    }
  end

  @doc """
  Stage (a) alone: the canonical claims this adapter derives from the envelopes — wire-shaped
  maps per docs/CLAIMS_CONTRACT.md, in emission order (identity, grouping, attribute,
  member_of), each carrying contract-C unix-second `"valid_from"`/`"recorded_at"`. This is what
  a customer's mapping script would produce and submit.
  """
  def canonical_claims(envelopes) when is_list(envelopes),
    do: canonical(envelopes, listing_periods(envelopes))

  defp canonical(envelopes, periods) do
    # Periods are emitted in listing order — Map iteration order is otherwise unspecified, which
    # would let stamp/1's tie-break drift between runs.
    sorted_periods = Enum.sort_by(periods, fn {k, _} -> k end)

    # A claim is ABOUT a code — cnk, ean, cn. There is no such thing as a claim without one, so
    # the anchor is the code the asserting source itself held AT THE TIME it spoke, read out of
    # that listing's periods. Three things follow, and each fixes a real hole:
    #
    #   * A source that later delisted keeps everything it said while it did hold codes. The old
    #     final-state fold erased a source's entire history the moment its last code went away.
    #   * A source that never asserted a code anchors to nothing. It used to be dropped in
    #     silence; now it is rejected, because an unaddressable claim is not worth keeping and
    #     the upstream should hear about it.
    #   * An unsourced event no longer borrows the entity's primary code. Manufacturing a link
    #     the source never made is the same error as merging two keys because a barcode matched.
    # ...and it links to ONE OR MORE of them, not one. So there is no "which code do we pick"
    # heuristic here at all: emit a claim per code the source held. An image carrying three EANs
    # links to three products, and a claim survives a split by attaching wherever its code went.
    # One identity claim PER PERIOD, not one per listing. A code that was attached and later
    # removed keeps an interval saying so, instead of silently never having existed — see
    # listing_periods/1 and docs/CLAIM_MAPPING_SPEC.md.
    identity =
      for {{e, s}, listing_periods} <- sorted_periods,
          period <- listing_periods do
        %{
          "kind" => "identity",
          "source" => s,
          "ref" => "#{e}:#{s}",
          "codes" => period.codes |> Enum.sort() |> Enum.map(&CanonicalClaims.code_string/1),
          "valid_from" => period.from,
          "valid_to" => period.to,
          "recorded_at" => period.from
        }
      end

    # Grouping tracks the same periods as identity. Dating it at the end of the fold left a
    # window where a code existed but belonged to no legacy product, so an as-of projection at
    # the first mint resolved to no product at all.
    grouping =
      for {{e, s}, listing_periods} <- sorted_periods,
          period <- listing_periods,
          code <- Enum.sort(period.codes) do
        %{
          "kind" => "grouping",
          "source" => s,
          "code" => CanonicalClaims.code_string(code),
          "product" => e,
          "valid_from" => period.from,
          "valid_to" => period.to,
          "recorded_at" => period.from
        }
      end

    attribute =
      for env <- envelopes,
          ev <- env.events,
          ev.kind == :attribute,
          code <- codes_at(periods, env.legacy_entity, ev.source, ev.recorded_at) do
        %{
          "kind" => "attribute",
          "source" => ev.source,
          "code" => CanonicalClaims.code_string(code),
          "field" => field_dim(ev),
          "value" => attribute_value(ev.data.field, ev.data.value),
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
          code <- codes_at(periods, env.legacy_entity, ev.source, ev.recorded_at) do
        %{
          "kind" => "member_of",
          "source" => ev.source,
          "code" => CanonicalClaims.code_string(code),
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

        for id <- Enum.sort(ids) do
          {vf, at} = Map.fetch!(last, id)

          # One edge per product code the source held: the same image reaches every product it
          # was listed against, rather than only whichever code primary/1 happened to prefer.
          edges =
            for code <- codes_at(periods, entity, nil, at) do
              %{
                "kind" => "edge",
                "source" => source,
                "from" => "#{scheme}:#{id}",
                "relation" => relation,
                "to" => CanonicalClaims.code_string(code),
                "valid_from" => vf || at,
                "recorded_at" => at
              }
            end

          # The lane entity exists whether or not it currently reaches a product — an asset with
          # no live edge is orphaned, not deleted, and the edges come back when the codes do.
          [
            %{
              "kind" => "identity",
              "source" => source,
              "ref" => "#{collection}:#{id}",
              "codes" => ["#{scheme}:#{id}"],
              "entity" => lane,
              "valid_from" => vf || at,
              "recorded_at" => at
            }
            | edges
          ]
        end
      end)

    identity ++ grouping ++ attribute ++ member_of ++ List.flatten(lane_entities)
  end

  @doc false
  # The lane-collection table, in wire (string) spelling — FinerClaims derives its atom form
  # from this so there is one table, not two that must not drift.
  def lane_collections, do: @lane_collections

  @doc false
  # medipim :media events reference FIRST-CLASS entities by asset id (collection "descriptions"
  # or "media"), with real add/remove churn — fold them per (entity, source, collection) exactly
  # like identity codes, so only SURVIVING references become lane records + edges (snapshot-v1;
  # a removed asset simply does not survive the fold). Source falls back to the envelope's
  # source_system — these events carry source: nil in real dumps. Shared with FinerClaims.
  def lane_refs(envelopes) do
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

  @doc """
  Per-listing code-set PERIODS — `%{{entity, source} => [%{from:, to:, codes:}]}`.

  `fold_raw/1` answers "which codes does this listing carry now" and throws the history away. That
  is wrong for any code that can move: a barcode transferred to another pack leaves no trace that
  it was ever here, and the two packs then look like one thing that always had both.

  This replays the same events but snapshots the code set after each one, coalescing runs where
  the set did not change. Each period is half-open — `from` inclusive, `to` exclusive — and the
  last period has `to: nil`, meaning still applicable. A period whose set is empty is a delisting,
  and is kept: an identity claim with no codes retracts the listing.
  """
  def listing_periods(envelopes) when is_list(envelopes) do
    for env <- envelopes, ev <- env.events, ev.kind == :identity, reduce: %{} do
      acc ->
        key = {env.legacy_entity, ev.source}
        {raw, periods} = Map.get(acc, key, {%{}, []})
        raw = apply_identity(raw, ev)
        Map.put(acc, key, {raw, append_period(periods, engine_codes(raw), ev.recorded_at)})
    end
    |> Map.new(fn {key, {_raw, periods}} -> {key, Enum.reverse(periods)} end)
  end

  # Periods accumulate newest-first. An event that does not change the set extends the current
  # period rather than starting one; an event that does change it closes the current period at
  # this timestamp and opens the next.
  defp append_period([%{codes: codes} | _] = periods, codes, _at), do: periods

  # Several events routinely land on the same day, sometimes the same second. Every reader of a
  # period works at DAY granularity — Bitemporal.effective?/2 compares Dates — so a period that
  # opens and closes within one day can never apply to any date. The later set replaces it rather
  # than leaving an empty interval behind, which the live-wire contract would reject anyway
  # ("valid_to must be later than valid_from").
  defp append_period([%{from: from} | rest], codes, at) when div(from, 86_400) == div(at, 86_400),
    do: [%{from: from, to: nil, codes: codes} | rest]

  defp append_period([current | rest], codes, at),
    do: [%{from: at, to: nil, codes: codes}, %{current | to: at} | rest]

  defp append_period([], codes, at), do: [%{from: at, to: nil, codes: codes}]

  @doc false
  # Half-open: from inclusive, to exclusive, nil to means still applicable.
  def covers?(%{from: from, to: to}, at), do: at >= from and (is_nil(to) or at < to)

  @doc false
  # The identifiers a claim is about, as of the instant it was made.
  #
  # A SOURCED event is about the codes that source itself held then — or, when it held none at
  # that instant but did identify this listing at some point, the nearest codes it held (gr-4iu,
  # see nearest_codes/2). Only a source that NEVER asserted a code on the listing is refused.
  #
  # An UNSOURCED event is scoped to the legacy entity, and the entity id is an identifier in its
  # own right — that is exactly what grouping claims make first-class. So it is about every code
  # the entity carried at that instant, across listings. This is not the same as borrowing another
  # source's code: the event never claimed to come from a source at all.
  def codes_at(periods, entity, nil, at) do
    periods
    |> Enum.filter(fn {{e, _source}, _} -> e == entity end)
    |> Enum.flat_map(fn {_key, ps} -> codes_covering(ps, at) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def codes_at(periods, entity, source, at) do
    ps = Map.get(periods, {entity, source}, [])

    case codes_covering(ps, at) do
      [] -> ps |> nearest_codes(at) |> Enum.sort()
      codes -> Enum.sort(codes)
    end
  end

  # gr-4iu: a source that DID identify this listing but spoke outside the window it held codes
  # anchors to the codes it held nearest in the past (bridging a delisting gap), or — before it
  # first identified — to the earliest codes it ever asserted on this listing. The listing ref is
  # the thread of continuity; the code set is merely late. A source that never asserted a code on
  # the listing still anchors to nothing and the event is refused (see rejected/1).
  defp nearest_codes(ps, at) do
    held = Enum.filter(ps, &(MapSet.size(&1.codes) > 0))

    held
    |> Enum.take_while(&(&1.from <= at))
    |> List.last()
    |> then(fn
      %{codes: codes} -> MapSet.to_list(codes)
      nil -> with([%{codes: codes} | _] <- held, do: MapSet.to_list(codes), else: ([] -> []))
    end)
  end

  # Periods are half-open, so the period OPENING at an instant owns it — right for identity,
  # wrong for an attribute stated in the same batch as a delisting: the source is describing
  # what it HAD, not the nothing it now has. At the exact instant a source delists, anchor
  # attributes to the codes the closing period held (gr-gh0).
  defp codes_covering(ps, at) do
    case Enum.find(ps, &covers?(&1, at)) do
      nil ->
        []

      %{codes: codes, from: from} ->
        if MapSet.size(codes) == 0 and from == at do
          case Enum.find(ps, &(&1.to == at)) do
            %{codes: parting} -> MapSet.to_list(parting)
            nil -> []
          end
        else
          MapSet.to_list(codes)
        end
    end
  end

  @doc """
  Events that cannot become claims, with the reason.

  A claim is about one or more identifiers. An event whose source held no code when it spoke has
  nothing to be about, so it is refused rather than dropped quietly — the count belongs in the
  backfill report, and the fix belongs upstream.
  """
  def rejected(envelopes) when is_list(envelopes), do: rejected(envelopes, listing_periods(envelopes))

  defp rejected(envelopes, periods) do
    for env <- envelopes,
        ev <- env.events,
        ev.kind in [:attribute, :edge],
        codes_at(periods, env.legacy_entity, ev.source, ev.recorded_at) == [] do
      %{
        entity: env.legacy_entity,
        source: ev.source,
        kind: ev.kind,
        detail: rejection_detail(ev),
        recorded_at: ev.recorded_at,
        reason: if(is_nil(ev.source), do: :unsourced, else: :source_held_no_code)
      }
    end
  end

  defp rejection_detail(%{kind: :attribute} = ev), do: field_dim(ev)
  defp rejection_detail(%{kind: :edge} = ev), do: ev.data.collection

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
  defp attribute_value(field, [single]), do: normalize_quantity(field, single)
  defp attribute_value(field, value), do: normalize_quantity(field, value)

  # Quantity fields with a DECLARED storage unit (gr-sx7.3, closing the spec's former OPEN
  # QUESTION): medipim stores weight in grams and dimensions in millimetres; "<num>_<unit>"
  # strings are a later editorial serialization of the SAME fact. Proven against the AU export —
  # the same org wrote `depth 43` and later `"4.3_cm"` on the same entity (and `99` next to
  # `"100_g"`, `68` next to `"0.065_kg"`). Normalisation is declaration-driven, never sniffed:
  # an undeclared field's digits-only string (hsCode, ospId, …) passes through untouched.
  @quantity_units %{
    "weight" => %{"g" => 1, "kg" => 1000},
    "width" => %{"mm" => 1, "cm" => 10},
    "depth" => %{"mm" => 1, "cm" => 10},
    "length" => %{"mm" => 1, "cm" => 10}
  }

  @doc false
  # Shared with FinerClaims — both folds must serialize a quantity the same way. An unparseable
  # or unknown-unit string is carried unchanged: honest, and survivorship will surface it.
  def normalize_quantity(field, value) when is_binary(value) do
    with %{} = units <- Map.get(@quantity_units, field, :undeclared),
         [num, unit] <- String.split(value, "_"),
         {:ok, factor} <- Map.fetch(units, unit),
         true <- Regex.match?(~r/^\d+(\.\d+)?$/, num),
         {n, ""} <- Float.parse(num) do
      scaled = n * factor
      rounded = round(scaled)
      if abs(scaled - rounded) < 1.0e-9, do: rounded, else: scaled
    else
      _ -> value
    end
  end

  def normalize_quantity(_field, value), do: value

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
  # Shared with FinerClaims — both folds must agree on what may never bridge. The predicate
  # itself is engine-owned (Codes.shared?, GH #56).
  defdelegate shared?(code), to: Codes

  # chronological order: later recorded_at ⇒ higher order. Stable on the original emission index.
  defp stamp(claims) do
    claims
    |> Enum.with_index()
    |> Enum.sort_by(fn {c, i} -> {c.recorded_at, i} end)
    |> Enum.with_index()
    |> Enum.map(fn {{c, _i}, order} -> %{c | order: order} end)
  end
end
