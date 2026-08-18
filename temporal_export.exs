# temporal_export.exs — export the temporal-pass demo to JSON for the viz/ web app (beads gr-m6r/gr-4ec).
#
#   Run:  mix run temporal_export.exs   ->   viz/src/data/temporal.json
#
# Runs the REAL engine primitives (Codes / Cluster / IdentityLedger / History from
# lib/golden_record_core.ex) on the medipim 422156 fixture + a synthetic over-merge case, and writes a
# faithful snapshot the Astro/React viz reads. The browser reimplements no fold logic — it indexes the
# precomputed projections by date.
#
# FINER-GRAINED IDENTITY (prototype — gr-4ec) ──────────────────────────────────────────────────────
# The shipped `Temporal` pass folds over ClaimMapping's claims, which collapse each source-listing's
# identity to ONE final-code-set claim at its LATEST date — erasing 422156's real convergence history
# (it looks like a single mint). Here we fold FINER: snapshot each listing's accumulated identity AFTER
# each raw identity event, at its true date, then run the SAME cluster + fold-forward. That recovers the
# real arc — legacy product 422156 resolves into 1 → 2 golden variants (org 44 is a code-distinct
# identity for years), and when org 44's barcode/CNK finally line up, the over-merge guard raises a
# STANDING merge proposal rather than silently merging. Dead-barcode orphan keys (no code any source
# still claims) are retired from the as-of view. This finer fold is NOT yet in the engine — it's a
# presentation-layer prototype here. GENERATED FILE — do not hand-edit temporal.json; re-run this.

alias GoldenRecord.{Events, Codes, Substrate, Priority, Cluster, IdentityLedger, History}

defmodule TemporalExport do
  @fixture "test/ingest/fixtures/medipim_be_422156.json"
  @out "viz/src/data/temporal.json"
  @priority Priority.new(%{}, [])

  @national [:cnk, :cip_acl7, :cefip, :pzn, :sukl, :pzn_austria, :national_code, :cn]
  @non_bridging MapSet.new([:mpn, :supplier_ref])

  def run do
    data = %{real: real_scene(), synthetic: synthetic_scene()}
    File.mkdir_p!(Path.dirname(@out))
    File.write!(@out, JSON.encode!(data))
    IO.puts("wrote #{@out} (#{File.stat!(@out).size} bytes)")
  end

  # ── the real fixture, finer-grained: legacy product 422156 -> golden variants over time ──────────
  defp real_scene do
    env = HistoryEnvelope.load!(@fixture)
    claims = finer_claims([env])
    shared = shared_of(claims)
    {events, attributions} = fold_forward(claims, shared)
    log = claims ++ stamp_events(events, claims)
    dates = identity_dates(claims)

    %{
      label: "legacy product 422156",
      dates: Enum.map(dates, &date_str/1),
      mintDate: date_str(List.first(dates)),
      timeline: events |> dedup_timeline() |> Enum.map(&event/1),
      asOf: Map.new(dates, fn d -> {date_str(d), as_of(log, claims, attributions, d)} end)
    }
  end

  # Project as known on `d`, grouped by product, with dead-barcode orphan keys retired, the over-merge
  # guard's standing merge proposals surfaced, and each variant attributed to its source orgs.
  defp as_of(log, claims, attributions, d) do
    listings = current_identity(claims, d)
    live = listings |> Enum.flat_map(& &1.data.codes) |> MapSet.new()
    grouped = History.project_as_of(log, d, @priority)

    # what each source currently claims, by its current identity snapshot.
    source_codes = Map.new(listings, fn l -> {to_string(l.source), MapSet.new(l.data.codes)} end)

    # sources attributed to a key on/before d (a source belongs to the key its codes last fit within).
    sources_for = fn key ->
      for(%{date: ad, key: ^key, source: s} <- attributions, Date.compare(ad, d) != :gt, do: s)
      |> Enum.uniq()
      |> Enum.sort()
    end

    # a key's CURRENT codes = the union its attributed sources actually claim now (which can exceed the
    # frozen ledger membership while a merge is gated). The proposal's `bridge` is where two keys overlap.
    current_codes = fn key ->
      key
      |> sources_for.()
      |> Enum.reduce(MapSet.new(), &MapSet.union(Map.get(source_codes, &1, MapSet.new()), &2))
    end

    products =
      for %{product: p, variants: vs} <- grouped,
          kept = Enum.filter(vs, &alive?(&1, live)),
          kept != [] do
        %{product: product_value(p), variants: Enum.map(kept, &variant(&1, sources_for.(&1.key)))}
      end

    kept_keys = products |> Enum.flat_map(& &1.variants) |> Enum.map(& &1.key) |> MapSet.new()

    # keys whose codes no source still claims — dead-barcode orphans (e.g. org 44's swapped-out
    # barcode). Surfaced separately so the timeline shows where a retired key went, not just a gap.
    retired =
      for %{variants: vs} <- grouped, v <- vs, not alive?(v, live), do: variant(v, sources_for.(v.key))

    proposals =
      for(
        %Events.ConflictFlagged{subject: {:merge, keys}, recorded_at: at} <- log,
        Date.compare(at, d) != :gt,
        do: Enum.sort(keys)
      )
      |> Enum.uniq()
      |> Enum.filter(fn keys -> Enum.all?(keys, &MapSet.member?(kept_keys, &1)) end)
      |> Enum.map(fn keys ->
        bridge =
          keys
          |> Enum.map(current_codes)
          |> Enum.reduce(&MapSet.intersection/2)
          |> MapSet.to_list()
          |> Enum.sort()
          |> Enum.map(&code_str/1)

        %{keys: keys, bridge: bridge}
      end)

    %{products: products, proposals: proposals, retired: retired}
  end

  defp alive?(variant, live_codes), do: Enum.any?(variant.codes, &MapSet.member?(live_codes, &1))

  defp variant(v, sources \\ []) do
    %{
      key: v.key,
      cnk: v.codes |> Enum.find(&match?({:cnk, _}, &1)) |> code_str(),
      codes: Enum.map(v.codes, &code_str/1),
      sources: sources
    }
  end

  # each source's current identity snapshot (one claim per source) as known on `d`.
  defp current_identity(claims, d) do
    claims
    |> Enum.filter(&(&1.kind == :identity and Date.compare(&1.recorded_at, d) != :gt))
    |> Substrate.current()
  end

  # ── finer fold: one identity snapshot per (listing, identity-event), plus product grouping ───────
  defp finer_claims(envelopes) do
    raw =
      for env <- envelopes,
          {source, evs} <- group_identity(env),
          claim <- snapshots(env.legacy_entity, source, evs) do
        claim
      end

    stamp(raw)
  end

  defp group_identity(env) do
    env.events
    |> Enum.filter(&(&1.kind == :identity))
    |> Enum.group_by(& &1.source)
    |> Enum.map(fn {s, evs} -> {s, Enum.sort_by(evs, & &1.recorded_at)} end)
  end

  # Replay one listing's identity deltas; after each event emit the accumulated identity claim (+
  # product-grouping claims for its codes) dated at that event. Skip snapshots that fold to empty.
  defp snapshots(entity, source, evs) do
    {claims, _raw} =
      Enum.reduce(evs, {[], %{}}, fn ev, {acc, raw} ->
        raw2 = apply_identity(raw, ev)
        codes = raw2 |> engine_codes() |> Enum.sort()
        d = to_date(ev.recorded_at)

        new =
          if codes == [] do
            []
          else
            id = Substrate.claim(source, :identity, %{ref: "#{entity}:#{source}", codes: codes}, d, d)
            grp = for c <- codes, do: Substrate.claim(source, :grouping, %{code: c, product: entity}, d, d)
            [id | grp]
          end

        {acc ++ new, raw2}
      end)

    claims
  end

  # delta semantics, mirroring ClaimMapping.apply_identity (on medipim scheme names).
  defp apply_identity(raw, ev) do
    s = ev.data.scheme
    c = ev.data.code

    case ev.op do
      :set when is_nil(c) -> Map.delete(raw, s)
      :set -> Map.put(raw, s, MapSet.new([c]))
      :add -> Map.update(raw, s, MapSet.new([c]), &MapSet.put(&1, c))
      :remove -> raw |> Map.update(s, MapSet.new(), &MapSet.delete(&1, c)) |> drop_empty(s)
      :delete -> Map.delete(raw, s)
    end
  end

  defp drop_empty(raw, s) do
    case Map.get(raw, s) do
      %MapSet{} = set -> if MapSet.size(set) == 0, do: Map.delete(raw, s), else: raw
      _ -> raw
    end
  end

  defp engine_codes(raw) do
    for {scheme, vals} <- raw, v <- vals, into: MapSet.new() do
      Codes.canonicalize({CodeRegistry.scheme(scheme), v})
    end
  end

  # ── fold-forward (mirrors Temporal.run, over the finer date-typed claims) ────────────────────────
  # Returns {identity events, source attributions}. A source is attributed to a key at date d when its
  # current codes fit WITHIN that key's membership — so it tracks the key it cleanly belongs to and is
  # NOT re-homed when the over-merge guard gates a bridge (its spanning codes fit no single key).
  defp fold_forward(claims, shared) do
    dates = identity_dates(claims)

    {rev, attrs, _ledger} =
      Enum.reduce(dates, {[], [], IdentityLedger.new()}, fn d, {acc, attrs, prev} ->
        live =
          claims
          |> Enum.filter(&(&1.kind == :identity and Date.compare(&1.recorded_at, d) != :gt))
          |> Substrate.current()

        clusters = Cluster.variants(live, shared)
        evs = IdentityLedger.decide(prev, {:reconcile, clusters, shared, d})
        led = Enum.reduce(evs, prev, &IdentityLedger.evolve(&2, &1))

        day_attrs =
          for {key, membership} <- led.members,
              l <- live,
              MapSet.subset?(MapSet.new(l.data.codes), membership),
              do: %{date: d, key: key, source: to_string(l.source)}

        {Enum.reverse(evs, acc), day_attrs ++ attrs, led}
      end)

    {Enum.reverse(rev), attrs}
  end

  # Keep all mint/members/merge/split; collapse the guard's re-proposed FLAGs to the FIRST per subject.
  defp dedup_timeline(events) do
    {kept, _seen} =
      Enum.reduce(events, {[], MapSet.new()}, fn e, {acc, seen} ->
        case e do
          %Events.ConflictFlagged{subject: subject} ->
            if MapSet.member?(seen, subject),
              do: {acc, seen},
              else: {[e | acc], MapSet.put(seen, subject)}

          _ ->
            {[e | acc], seen}
        end
      end)

    Enum.reverse(kept)
  end

  # ── synthetic over-merge guard (unchanged) ───────────────────────────────────────────────────────
  defp synthetic_scene do
    d1 = ~D[2024-01-01]
    d2 = ~D[2024-06-01]

    envs = [
      envelope(900, [
        id("C", "gtin", "05000000000017", epoch(d1, 9)),
        id("D", "cnk", "1000000", epoch(d1, 9)),
        id("E", "gtin", "05000000000017", epoch(d2, 9)),
        id("E", "cnk", "1000000", epoch(d2, 9))
      ])
    ]

    %{log: log, timeline: timeline} = Temporal.run(envs)

    %{
      label: "over-merge guard (synthetic)",
      steps: [date_str(d1), date_str(d2)],
      timeline: Enum.map(timeline, &event/1),
      asOf: synthetic_as_of(log, [d1, d2])
    }
  end

  defp synthetic_as_of(log, dates) do
    Map.new(dates, fn d ->
      variants =
        log
        |> Temporal.golden_as_of(d)
        |> Enum.flat_map(& &1.variants)
        |> Enum.map(&variant/1)

      {date_str(d), %{variants: variants}}
    end)
  end

  # ── shared helpers ───────────────────────────────────────────────────────────────────────────────
  defp shared_of(claims) do
    for c <- claims,
        c.kind == :identity,
        code <- c.data.codes,
        Codes.restricted?(code) or MapSet.member?(@non_bridging, elem(code, 0)),
        into: MapSet.new(),
        do: code
  end

  defp identity_dates(claims),
    do:
      claims
      |> Enum.filter(&(&1.kind == :identity))
      |> Enum.map(& &1.recorded_at)
      |> Enum.uniq()
      |> Enum.sort(Date)

  defp product_value(p) when is_integer(p), do: p
  defp product_value(_), do: nil

  defp stamp(claims) do
    claims
    |> Enum.with_index()
    |> Enum.sort_by(fn {c, i} -> {sort_key(c.recorded_at), i} end)
    |> Enum.with_index()
    |> Enum.map(fn {{c, _i}, order} -> %{c | order: order} end)
  end

  defp stamp_events(events, claims) do
    base = claims |> Enum.map(& &1.order) |> Enum.max(fn -> -1 end)
    events |> Enum.with_index(base + 1) |> Enum.map(fn {e, o} -> %{e | order: o} end)
  end

  defp sort_key(%Date{} = d), do: Date.to_erl(d)
  defp sort_key(epoch) when is_integer(epoch), do: epoch

  defp event(%Events.IdentityMinted{key: k, codes: c, recorded_at: at}),
    do: %{date: date_str(at), type: "MINT", key: k, codes: codes_str(c)}

  defp event(%Events.IdentityMembersChanged{key: k, codes: c, recorded_at: at}),
    do: %{date: date_str(at), type: "MEMBERS", key: k, codes: codes_str(c)}

  defp event(%Events.IdentitiesMerged{from: from, into: into, recorded_at: at}),
    do: %{date: date_str(at), type: "MERGE", from: from, into: into}

  defp event(%Events.IdentitySplit{key: k, into: into, recorded_at: at}),
    do: %{date: date_str(at), type: "SPLIT", key: k, into: Enum.map(into, &elem(&1, 0))}

  defp event(%Events.ConflictFlagged{subject: {:merge, keys}, recorded_at: at}),
    do: %{date: date_str(at), type: "FLAG", subject: keys}

  defp event(%Events.ConflictFlagged{subject: subject, recorded_at: at}),
    do: %{date: date_str(at), type: "FLAG", subject: inspect(subject)}

  defp codes_str(%MapSet{} = codes), do: codes |> MapSet.to_list() |> Enum.sort() |> codes_str()
  defp codes_str(codes) when is_list(codes), do: Enum.map(codes, &code_str/1)
  defp code_str(nil), do: nil
  defp code_str({scheme, value}), do: "#{scheme}:#{value}"

  defp date_str(%Date{} = d), do: Date.to_iso8601(d)
  defp to_date(epoch), do: epoch |> DateTime.from_unix!() |> DateTime.to_date()

  # ── synthetic-envelope helpers ───────────────────────────────────────────────────────────────────
  defp envelope(entity, events) do
    {:ok, env} =
      HistoryEnvelope.from_map(%{"schema_version" => "1", "legacy_entity" => entity, "events" => events})

    env
  end

  defp id(source, scheme, code, at),
    do: %{
      "recorded_at" => at,
      "source" => source,
      "op" => "set",
      "kind" => "identity",
      "scheme" => scheme,
      "code" => code
    }

  defp epoch(%Date{} = date, hour),
    do: date |> DateTime.new!(Time.new!(hour, 0, 0)) |> DateTime.to_unix()
end

TemporalExport.run()
