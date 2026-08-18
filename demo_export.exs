# demo_export.exs — export the story-demo scenes to JSON for the viz/ web app (bead gr-0cj).
#
#   Run:  mix run demo_export.exs   ->   viz/src/data/story.json
#
# Drives the REAL engine (Substrate / Cluster / IdentityLedger / Survivorship / Stewardship /
# History from lib/golden_record_core.ex) through three synthetic story scenarios, capturing a
# named snapshot after each beat: the claim log so far, the events that beat emitted, the
# projected golden record(s), and the open steward queue. The viz replays snapshots; it computes
# nothing. The `oldWay` scene is the one hand-authored exception — destructive merging is what
# this engine refuses to do, so it cannot be engine-exported (the viz labels it an illustration).
#
# The story each scene tells (design: docs/plans/2026-06-10-story-demo-design.md):
#   claims   — sources assert code-anchored claims; a golden record materializes as a fold.
#   priority — three sources disagree on weight; tiers rank them; a top-tier tie goes to the steward.
#   record   — one upstream record is revised over time (replace/patch/withdraw/reactivate); the
#              stable key survives the delisting because the record→key binding is permanent.
#   clocks   — a late, bounded correction: "what did we know" and "what was true" are two clocks,
#              so the same question asked before and after the correction answers differently.
#   mistake  — a steward approves a wrong merge; the contradiction surfaces (evidence was never
#              destroyed); the steward splits; every attribute and media claim re-homes by code.
#
# GENERATED FILE — do not hand-edit story.json; re-run this script.

alias GoldenRecord.{Events, Substrate, Priority, Cluster, IdentityLedger, Stewardship, History}

defmodule DemoExport do
  @out "viz/src/data/story.json"

  # the source-record scenes speak for one upstream record: {source, ref} must be strings
  @source "supplier"
  @ref "SUP-88431"

  def run do
    data = %{
      oldWay: old_way(),
      claims: claims_scene(),
      priority: priority_scene(),
      record: record_scene(),
      clocks: clocks_scene(),
      mistake: mistake_scene()
    }

    File.mkdir_p!(Path.dirname(@out))
    File.write!(@out, JSON.encode!(data))
    IO.puts("wrote #{@out} (#{File.stat!(@out).size} bytes)")
  end

  # ── chapter 1: the old way (hand-authored — the engine refuses to do this) ───────────────────────
  defp old_way do
    a = %{
      source: "Import A",
      code: "gtin:05410013100072",
      name: "Sunscreen SPF 50 — 200 ml",
      weight_g: 250,
      image: "img-a"
    }

    b = %{
      source: "Import B",
      code: "gtin:08712345678906",
      name: "Sunscreen SPF50 200ml (tube)",
      weight_g: 480,
      image: "img-b"
    }

    merged = %{
      source: nil,
      codes: [a.code, b.code],
      name: a.name,
      weight_g: a.weight_g,
      image: a.image
    }

    %{
      label: "the old way (illustration)",
      steps: [
        %{id: "two-records", a: a, b: b},
        %{id: "match", a: a, b: b, matchedOn: "name similarity"},
        %{id: "merge", merged: merged, lost: ["weight 480 g", "image img-b", "which source said what"]},
        %{
          id: "import",
          merged: %{merged | weight_g: 480, source: "Import C"},
          lost: ["weight 250 g — overwritten in place", "any way back"]
        }
      ]
    }
  end

  # ── chapter 2: claims, not records ────────────────────────────────────────────────────────────────
  defp claims_scene do
    priority = Priority.new(%{}, [[:manufacturer], [:supplier]])
    gtin = {:gtin, "05410013100072"}
    cnk = {:cnk, "1234567"}

    beats = [
      {"first-claim", ~D[2026-01-05],
       {:claims,
        [
          identity(:manufacturer, "MFR-SUN50", [gtin], ~D[2026-01-05]),
          attribute(:manufacturer, gtin, :name, "Sunscreen SPF 50 — 200 ml", ~D[2026-01-05])
        ]}},
      {"first-attribute", ~D[2026-01-12],
       {:claims, [attribute(:manufacturer, gtin, :weight_g, 250, ~D[2026-01-12])]}},
      {"second-source", ~D[2026-02-03],
       {:claims, [identity(:supplier, "SUP-88431", [cnk, gtin], ~D[2026-02-03])]}},
      {"media", ~D[2026-02-10],
       {:claims,
        [
          Substrate.claim(
            :supplier,
            :media,
            %{asset: {:dam, "IMG-1"}, target: cnk, role: :primary, uri: "cdn://sunscreen-front"},
            ~D[2026-02-10],
            ~D[2026-02-10]
          )
        ]}}
    ]

    %{label: "claims, not records", tiers: tiers_view(priority), steps: run_beats(beats, priority)}
  end

  # ── chapter 3: who wins? ──────────────────────────────────────────────────────────────────────────
  defp priority_scene do
    # weight has strict tiers; color deliberately puts manufacturer and supplier in ONE tier,
    # so a disagreement is honestly undecidable -> steward.
    priority =
      Priority.new(
        %{color: [[:manufacturer, :supplier], [:marketplace]]},
        [[:manufacturer], [:supplier], [:marketplace]]
      )

    gtin = {:gtin, "05410013100072"}

    beats = [
      {"one-product", ~D[2026-03-01],
       {:claims,
        [
          identity(:manufacturer, "MFR-SUN50", [gtin], ~D[2026-03-01]),
          identity(:supplier, "SUP-88431", [gtin], ~D[2026-03-01]),
          identity(:marketplace, "MKT-9917", [gtin], ~D[2026-03-01])
        ]}},
      {"marketplace-weight", ~D[2026-03-02],
       {:claims, [attribute(:marketplace, gtin, :weight_g, 300, ~D[2026-03-02])]}},
      {"supplier-weight", ~D[2026-03-09],
       {:claims, [attribute(:supplier, gtin, :weight_g, 260, ~D[2026-03-09])]}},
      {"manufacturer-weight", ~D[2026-03-16],
       {:claims, [attribute(:manufacturer, gtin, :weight_g, 250, ~D[2026-03-16])]}},
      {"color-tie", ~D[2026-03-20],
       {:claims,
        [
          attribute(:manufacturer, gtin, :color, "white", ~D[2026-03-20]),
          attribute(:supplier, gtin, :color, "ivory", ~D[2026-03-20])
        ]}},
      {"steward-pick", ~D[2026-03-27],
       {:steward,
        fn _ledger -> Stewardship.resolve_attribute("SK_1", :color, "ivory", :sam, ~D[2026-03-27]) end}}
    ]

    %{label: "who wins?", tiers: tiers_view(priority), steps: run_beats(beats, priority)}
  end

  # ── chapter 4: the record keeps changing (source-record lifecycle) ───────────────────────────────
  # One upstream record, addressed by {source, ref} and revised atomically. The reactivation
  # deliberately returns with entirely DIFFERENT codes: nothing in the evidence connects it to the
  # original, so the key can only survive through the permanent record→key binding.
  defp record_scene do
    priority = Priority.new(%{}, [[@source]])
    cnk = {:cnk, "1000001"}
    gtin = {:gtin, "05012345678900"}
    new_cnk = {:cnk, "1000914"}
    new_gtin = {:gtin, "05012345679907"}

    beats = [
      {"v1-replace",
       [
         revision: "1",
         operation: :replace,
         valid_from: ~D[2026-01-01],
         recorded_at: ts(~D[2026-01-10]),
         claims: [
           identity(@source, @ref, [cnk, gtin], ~D[2026-01-01]),
           attribute(@source, cnk, :name, "Zinc oxide paste 30 g", ~D[2026-01-01]),
           attribute(@source, cnk, :weight_g, 250, ~D[2026-01-01])
         ]
       ]},
      {"v2-patch",
       [
         revision: "2",
         base_revision: "1",
         operation: :patch,
         valid_from: ~D[2026-02-14],
         recorded_at: ts(~D[2026-02-14]),
         claims: [attribute(@source, cnk, :weight_g, 260, ~D[2026-02-14])]
       ]},
      {"v3-withdraw",
       [
         revision: "3",
         base_revision: "2",
         operation: :withdraw,
         valid_from: ~D[2026-03-01],
         recorded_at: ts(~D[2026-03-01])
       ]},
      {"v4-reactivate",
       [
         revision: "4",
         base_revision: "3",
         operation: :reactivate,
         valid_from: ~D[2026-04-01],
         recorded_at: ts(~D[2026-04-01]),
         claims: [
           identity(@source, @ref, [new_cnk, new_gtin], ~D[2026-04-01]),
           attribute(@source, new_cnk, :name, "Zinc oxide paste 30 g", ~D[2026-04-01]),
           attribute(@source, new_cnk, :weight_g, 260, ~D[2026-04-01])
         ]
       ]}
    ]

    %{
      label: "the record keeps changing",
      tiers: tiers_view(priority),
      steps: run_record_beats(beats, priority)
    }
  end

  # ── chapter 6: two clocks ─────────────────────────────────────────────────────────────────────────
  # A bounded correction recorded in April says the pack was different for nine days in February.
  # Every cell of the grid is the engine's own answer for one (known_at, effective_at) pair.
  defp clocks_scene do
    priority = Priority.new(%{}, [[@source]])
    ref = "SUP-77120"
    cnk = {:cnk, "1000042"}
    regular = "Zinc oxide paste 30 g"
    promo = "Zinc oxide paste 50 g — promo pack"

    first =
      revise!(nil,
        ref: ref,
        revision: "1",
        operation: :replace,
        valid_from: ~D[2026-01-01],
        recorded_at: ts(~D[2026-01-10]),
        claims: [
          identity(@source, ref, [cnk], ~D[2026-01-01]),
          attribute(@source, cnk, :name, regular, ~D[2026-01-01])
        ]
      )

    correction =
      revise!(first,
        ref: ref,
        revision: "2",
        base_revision: "1",
        operation: :replace,
        valid_from: ~D[2026-02-01],
        valid_to: ~D[2026-02-10],
        recorded_at: ts(~D[2026-04-01]),
        claims: [
          identity(@source, ref, [cnk], ~D[2026-02-01]),
          attribute(@source, cnk, :name, promo, ~D[2026-02-01])
        ]
      )

    {[first], order} = stamp([first], 0)
    {bindings, order} = bind_key([first], first, order)
    {[correction], _} = stamp([correction], order)
    log = [first] ++ bindings ++ [correction]

    known_axis = [~D[2026-01-15], ~D[2026-03-01], ~D[2026-04-02]]
    effective_axis = [~D[2026-01-20], ~D[2026-02-05], ~D[2026-02-10], ~D[2026-04-02]]

    %{
      label: "two clocks",
      revisions: revision_views([first, correction]),
      knownAxis: Enum.map(known_axis, &date_str/1),
      effectiveAxis: Enum.map(effective_axis, &date_str/1),
      cells: for(k <- known_axis, e <- effective_axis, do: cell_view(log, k, e, priority)),
      steps: [
        %{id: "ask-january", knownAt: date_str(~D[2026-03-01]), effectiveAt: date_str(~D[2026-01-20])},
        %{id: "before-correction", knownAt: date_str(~D[2026-03-01]), effectiveAt: date_str(~D[2026-02-05])},
        %{id: "after-correction", knownAt: date_str(~D[2026-04-02]), effectiveAt: date_str(~D[2026-02-05])},
        %{id: "window-closed", knownAt: date_str(~D[2026-04-02]), effectiveAt: date_str(~D[2026-02-10])}
      ]
    }
  end

  # ── chapter 8: the mistake is cheap ───────────────────────────────────────────────────────────────
  defp mistake_scene do
    # two manufacturers in the SAME weight tier: while the products are distinct there is no
    # conflict (one weight claim each) — the contradiction only becomes visible once fused.
    priority = Priority.new(%{weight_g: [[:acme, :bolt]]}, [[:acme], [:bolt]])

    ga = {:gtin, "05410013100072"}
    ka = {:cnk, "1234567"}
    gb = {:gtin, "08712345678906"}
    kb = {:cnk, "7654321"}

    beats = [
      {"two-products", ~D[2026-04-01],
       {:claims,
        [
          identity(:acme, "ACME-SUN", [ga, ka], ~D[2026-04-01]),
          attribute(:acme, ga, :name, "Sunscreen SPF 50 — 200 ml", ~D[2026-04-01]),
          attribute(:acme, ga, :weight_g, 250, ~D[2026-04-01]),
          Substrate.claim(
            :acme,
            :media,
            %{asset: {:dam, "IMG-A"}, target: ga, role: :primary, uri: "cdn://sun-a"},
            ~D[2026-04-01],
            ~D[2026-04-01]
          ),
          identity(:bolt, "BOLT-2114", [gb, kb], ~D[2026-04-01]),
          attribute(:bolt, gb, :name, "Sunscreen SPF50 200ml (tube)", ~D[2026-04-01]),
          attribute(:bolt, gb, :weight_g, 480, ~D[2026-04-01]),
          Substrate.claim(
            :bolt,
            :media,
            %{asset: {:dam, "IMG-B"}, target: gb, role: :primary, uri: "cdn://sun-b"},
            ~D[2026-04-01],
            ~D[2026-04-01]
          )
        ]}},
      {"wrong-merge", ~D[2026-04-15],
       {:steward,
        fn ledger -> Stewardship.approve_merge(ledger.members, ["SK_1", "SK_2"], :sam, ~D[2026-04-15]) end}},
      {"contradiction", ~D[2026-04-15], :pause},
      {"split", ~D[2026-05-02],
       {:steward, fn ledger -> Stewardship.split(ledger, "SK_1", [[gb, kb]], :sam, ~D[2026-05-02]) end}},
      {"healed", ~D[2026-05-02], :pause}
    ]

    %{label: "the mistake is cheap", tiers: tiers_view(priority), steps: run_beats(beats, priority)}
  end

  # The trust tiers, straight from the scene's ACTUAL Priority struct — the viz shows the same
  # ranking the engine resolves with, so the reasoning on screen can't drift from the engine.
  defp tiers_view(%Priority{table: table, default: default}) do
    rows = for {dim, tiers} <- Enum.sort_by(table, &elem(&1, 0)), do: %{dimension: dim, tiers: tiers}
    rows ++ [%{dimension: "default", tiers: default}]
  end

  # ── the beat engine: fold claims + steward decisions forward, snapshot after each beat ───────────
  defp run_beats(beats, priority, shared \\ MapSet.new()) do
    state = %{log: [], ledger: IdentityLedger.new(), order: 0}

    {steps, _} =
      Enum.map_reduce(beats, state, fn {id, d, action}, st ->
        {new_claims, steward_events} =
          case action do
            {:claims, cs} -> {cs, []}
            {:steward, decide} -> {[], decide.(st.ledger)}
            :pause -> {[], []}
          end

        {stamped_claims, o1} = stamp(new_claims, st.order)
        log1 = st.log ++ stamped_claims

        identity_events =
          case stamped_claims do
            [] -> []
            _ -> IdentityLedger.decide(st.ledger, {:reconcile, clusters(log1, shared), shared, d})
          end

        {stamped_events, o2} = stamp(identity_events ++ steward_events, o1)
        ledger = Enum.reduce(stamped_events, st.ledger, &IdentityLedger.evolve(&2, &1))
        log = log1 ++ stamped_events

        step = %{
          id: id,
          date: date_str(d),
          log: log |> claims_of() |> Enum.map(&claim_view/1),
          # a steward decision can also assert a claim (merge evidence) — that belongs in the log
          events:
            stamped_events |> Enum.reject(&match?(%Events.ClaimAsserted{}, &1)) |> Enum.map(&event_view/1),
          golden: golden_view(History.now(log, priority)),
          queue: queue_view(ledger.members, log, priority, d)
        }

        {step, %{log: log, ledger: ledger, order: o2}}
      end)

    steps
  end

  # ── the source-record beat engine: revise one record forward, snapshot after each revision ───────
  defp run_record_beats(beats, priority) do
    state = %{log: [], order: 0, current: nil, key: nil, revisions: []}

    {steps, _} =
      Enum.map_reduce(beats, state, fn {id, opts}, st ->
        revision = revise!(st.current, opts)
        {[revision], order} = stamp([revision], st.order)
        log = st.log ++ [revision]

        # Mirrors api/lib/api/writes.ex: bind the record to the key the engine resolved the first
        # time round and keep that binding forever — it is what carries identity across a delisting.
        {bindings, order} = if st.key, do: {[], order}, else: bind_key(log, revision, order)
        log = log ++ bindings
        key = st.key || bindings |> List.first() |> then(&(&1 && &1.key))
        revisions = st.revisions ++ [revision]

        step = %{
          id: id,
          date: date_str(revision.recorded_at),
          revisions: revision_views(revisions),
          current: revision.revision,
          boundKey: key,
          golden:
            golden_view(
              History.project_bitemporal(
                log,
                revision.recorded_at,
                Bitemporal.effective_date(revision.recorded_at),
                priority
              )
            )
        }

        {step, %{log: log, order: order, current: revision, key: key, revisions: revisions}}
      end)

    steps
  end

  defp revise!(current, opts) do
    {:ok, revision} = SourceRecords.revise(current, Keyword.merge([source: @source, ref: @ref], opts))
    revision
  end

  defp bind_key(log, revision, order) do
    identity = Enum.find(revision.claims, &(&1.kind == :identity))
    codes = MapSet.new(identity.data.codes)

    members =
      History.state_bitemporal(
        log,
        revision.recorded_at,
        Bitemporal.effective_date(revision.valid_from)
      ).members

    case Enum.find(members, fn {_key, held} -> MapSet.subset?(codes, held) end) do
      {key, _} ->
        stamp(
          [
            %Events.SourceRecordKeyBound{
              source: revision.source,
              ref: revision.ref,
              lane: :product,
              key: key,
              valid_from: revision.valid_from,
              recorded_at: revision.recorded_at
            }
          ],
          order
        )

      nil ->
        {[], order}
    end
  end

  # Every revision stores its COMPLETE snapshot, so `changed` is a diff against the previous
  # snapshot — computed here, never in the browser.
  defp revision_views(revisions) do
    {views, _} =
      Enum.map_reduce(revisions, %{}, fn revision, previous ->
        view = %{
          revision: revision.revision,
          operation: revision.operation,
          active: revision.active,
          recordedAt: date_str(revision.recorded_at),
          validFrom: date_str(revision.valid_from),
          validTo: revision.valid_to && date_str(revision.valid_to),
          facts: Enum.map(revision.claims, &fact_view(&1, previous))
        }

        {view, SourceRecords.claim_map(revision.claims)}
      end)

    views
  end

  defp fact_view(claim, previous) do
    %{slot: slot_str(Substrate.local_slot(claim)), kind: claim.kind, changed: changed?(claim, previous)}
    |> Map.merge(data_view(claim.kind, claim.data))
  end

  # "changed" answers what a viewer asks — did this FACT change? — so attributes compare by field
  # rather than by slot: re-listing under new codes moves every slot without touching a value.
  defp changed?(_claim, previous) when map_size(previous) == 0, do: false

  defp changed?(%{kind: :attribute, data: %{field: field, value: value}}, previous) do
    case find_previous(previous, &(&1.kind == :attribute and &1.data.field == field)) do
      nil -> true
      was -> was.data.value != value
    end
  end

  defp changed?(%{kind: :identity, data: %{codes: codes}}, previous) do
    case find_previous(previous, &(&1.kind == :identity)) do
      nil -> true
      was -> MapSet.new(was.data.codes) != MapSet.new(codes)
    end
  end

  defp changed?(claim, previous) do
    case Map.get(previous, Substrate.local_slot(claim)) do
      nil -> true
      was -> was.data != claim.data
    end
  end

  defp find_previous(previous, match?), do: Enum.find_value(previous, fn {_slot, c} -> match?.(c) && c end)

  defp slot_str(:identity), do: "identity"
  defp slot_str({:attr, _code, field}), do: "attribute:#{field}"
  defp slot_str({:media, asset, _target}), do: "media:#{code_str(asset)}"
  defp slot_str(other), do: inspect(other)

  # One answer of the two-clock grid: what we knew at `known_date` about the world on `effective_at`.
  defp cell_view(log, known_date, effective_at, priority) do
    known_at = ts(known_date)

    revision =
      log
      |> History.claims_bitemporal(known_at, effective_at)
      |> Enum.map(& &1.record_revision)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> List.first()

    variant =
      log
      |> History.project_bitemporal(known_at, effective_at, priority)
      |> Enum.flat_map(& &1.variants)
      |> List.first()

    %{
      knownAt: date_str(known_date),
      effectiveAt: date_str(effective_at),
      revision: revision,
      key: variant && variant.key,
      value: variant && field_value(variant, :name)
    }
  end

  defp field_value(variant, field) do
    case List.keyfind(variant.attributes, field, 0) do
      {^field, decision} -> decision.value
      nil -> nil
    end
  end

  defp ts(%Date{} = date), do: DateTime.new!(date, ~T[12:00:00], "Etc/UTC")

  defp identity(source, ref, codes, d),
    do: Substrate.claim(source, :identity, %{ref: ref, codes: codes}, d, d)

  defp attribute(source, code, field, value, d),
    do: Substrate.claim(source, :attribute, %{code: code, field: field, value: value}, d, d)

  defp claims_of(log), do: Enum.filter(log, &match?(%Events.ClaimAsserted{}, &1))
  defp clusters(log, shared), do: Cluster.variants(Substrate.current(claims_of(log)), shared)

  defp stamp(entries, start),
    do:
      {entries |> Enum.with_index(start) |> Enum.map(fn {e, i} -> %{e | order: i} end),
       start + length(entries)}

  # ── views (everything below is serialization, no decisions) ──────────────────────────────────────
  defp claim_view(%Events.ClaimAsserted{} = c) do
    %{order: c.order, source: c.source, kind: c.kind, date: date_str(c.recorded_at)}
    |> Map.merge(data_view(c.kind, c.data))
  end

  defp data_view(:identity, d), do: %{ref: d.ref, codes: Enum.map(d.codes, &code_str/1)}
  defp data_view(:attribute, d), do: %{code: code_str(d.code), field: d.field, value: d.value}

  defp data_view(:media, d),
    do: %{asset: code_str(d.asset), target: code_str(d.target), uri: d.uri}

  # An approved merge records WHY it merged: the steward's own same-product evidence, in the log
  # alongside the sources' claims — which is why a later split can undo it without re-importing.
  defp data_view(:identity_evidence, d),
    do: %{
      left: code_str(d.left),
      right: code_str(d.right),
      relation: d.relation,
      by: to_string(d.by),
      reason: d.reason
    }

  defp golden_view(grouped) do
    for %{variants: vs} <- grouped, v <- vs do
      %{
        key: v.key,
        codes: Enum.map(v.codes, &code_str/1),
        attributes: Enum.map(v.attributes, &attribute_view/1),
        media: Enum.map(v.media, &%{asset: code_str(&1.asset), source: &1.source, uri: &1.uri})
      }
    end
    |> Enum.sort_by(& &1.key)
  end

  defp attribute_view({field, decision}) do
    %{
      field: field,
      value: decision.value,
      winner: winner_str(decision.winner),
      status: decision.status,
      candidates: Enum.map(decision.candidates, fn {s, v} -> %{source: s, value: v} end)
    }
  end

  # The OPEN steward queue: every conflict the engine cannot settle, minus subjects a steward
  # already resolved. Attribute ties are detected fresh each step (they are a projection, not log
  # entries); merge proposals live in the log because the ledger's reconcile emits them.
  defp queue_view(members, log, priority, d) do
    live = log |> claims_of() |> Substrate.current()
    resolved = for %Events.ConflictResolved{subject: s} <- log, into: MapSet.new(), do: s

    attr_flags =
      for %Events.ConflictFlagged{subject: {:attr, k, f}, candidates: cands} <-
            Stewardship.detect(members, live, priority, d),
          not MapSet.member?(resolved, {:attr, k, f}) do
        %{
          type: "attr",
          key: k,
          field: f,
          candidates: Enum.map(cands, fn {s, v} -> %{source: s, value: v} end)
        }
      end

    merge_flags =
      for(%Events.ConflictFlagged{subject: {:merge, keys}} <- log, do: Enum.sort(keys))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(resolved, {:merge, &1}))
      |> Enum.map(&%{type: "merge", keys: &1})

    attr_flags ++ merge_flags
  end

  defp event_view(%Events.IdentityMinted{key: k, codes: c, recorded_at: at}),
    do: %{date: date_str(at), type: "MINT", key: k, codes: codes_str(c)}

  defp event_view(%Events.IdentityMembersChanged{key: k, codes: c, recorded_at: at}),
    do: %{date: date_str(at), type: "MEMBERS", key: k, codes: codes_str(c)}

  defp event_view(%Events.IdentitiesMerged{from: from, into: into, recorded_at: at}),
    do: %{date: date_str(at), type: "MERGE", from: from, into: into}

  defp event_view(%Events.IdentitySplit{key: k, kept_codes: kept, into: into, recorded_at: at}),
    do: %{
      date: date_str(at),
      type: "SPLIT",
      key: k,
      kept: codes_str(kept),
      into: Enum.map(into, fn {nk, c} -> %{key: nk, codes: codes_str(c)} end)
    }

  defp event_view(%Events.ConflictFlagged{subject: {:merge, keys}, recorded_at: at}),
    do: %{date: date_str(at), type: "FLAG", keys: keys}

  defp event_view(%Events.ConflictResolved{subject: subject, decision: decision, by: by, recorded_at: at}),
    do: %{
      date: date_str(at),
      type: "DECISION",
      subject: subject_str(subject),
      decision: decision_str(decision),
      by: by
    }

  defp subject_str({:attr, key, field}), do: "#{key}/#{field}"
  defp subject_str({:merge, keys}), do: Enum.join(keys, "+")
  defp subject_str({:split, key}), do: key
  defp subject_str(other), do: inspect(other)

  defp decision_str({:pick, value}), do: "pick #{value}"
  defp decision_str(other), do: to_string(other)

  defp winner_str(nil), do: nil
  defp winner_str(w), do: to_string(w)

  defp codes_str(%MapSet{} = codes), do: codes |> MapSet.to_list() |> Enum.sort() |> Enum.map(&code_str/1)
  defp codes_str(codes) when is_list(codes), do: Enum.map(codes, &code_str/1)
  defp code_str({scheme, value}), do: "#{scheme}:#{value}"

  defp date_str(%Date{} = d), do: Date.to_iso8601(d)
  defp date_str(%DateTime{} = dt), do: dt |> DateTime.to_date() |> Date.to_iso8601()
end

DemoExport.run()
