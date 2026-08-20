# lib/ingest/parity.ex — the whole-product parity harness (gr-yfh). THE cutover gate.
#
# Generalizes the single-entity 422156 byte-test (test/ingest/ingest_walkthrough_test.exs,
# php/bench/dump_golden_422156.exs) from "one fixture, hand-asserted" to "a cohort, classified":
# fold each legacy history through the engine, render the result as a materialized product
# SNAPSHOT, diff it field-by-field against the snapshot medipim's ProductDeltaApplier materializes
# for the same product, and CLASSIFY every divergence so gr-be3 can close the gaps one class at a
# time. Nothing here decides identity, survivorship or classification — it is a pure fold over
# what GoldenRecords/Rederivation already produce, plus a diff (cf. MigrationDiff, same posture).
#
# WHY the applier side is an INPUT FILE, not something we compute ─────────────────────────────────
# ProductDeltaApplier lives in medipim, on the other side of the contract-C wall (see the fixtures
# README, "Why a one-off oracle and not the production loader"). This repo cannot run it, and
# re-implementing it here would prove parity against our own guess. So the harness CONSUMES
# applier-materialized snapshots: one JSON file per product, exported by medipim, paired with the
# contract-C envelope of the same product. `snapshot/3` renders the engine side into that same wire
# shape, so the diff is a plain map/set diff in one shared vocabulary.
#
# THE WIRE SHAPE — this is the export contract for the at-scale cohort (gr-1c6.3) ────────────────
#
#     <stem>.json           the contract-C HistoryEnvelope (what the engine folds)
#     <stem>.snapshot.json  the materialized snapshot for the SAME product:
#
#     {"schema_version": "1",
#      "produced_by":    "applier",              # "engine" marks a self-comparison — see below
#      "source_system":  "medipim-be",
#      "legacy_entity":  422156,
#      "identity":       ["cnk:3612173", "gtin:03282770146004"],   # "scheme:value", canonicalized
#      "attributes":     {"name:nl": "…", "status": "active", "weight": 859},  # "field[:locale]"
#      "edges":          ["brands:9", "labos:549", "organizations:1035"],      # "collection:member"
#      "media":          ["158717", "578550"],   # the LEGACY asset ids, as strings
#      "descriptions":   ["401512", "401617"]}   # the LEGACY text ids, as strings
#
# All five lanes are REQUIRED (`load_snapshot!/1` refuses a file missing one), because an omitted
# lane would read as "the applier holds nothing here" and silently manufacture engine_only
# divergences — the one failure mode that would make a green gate a lie. Values must carry their
# native JSON types (`859`, not `"859"`) and a field the applier holds as null must be exported as
# an explicit `null`: the diff is strict, so type-punning shows up as value_mismatch, by design.
#
# The engine snapshot adds two keys the applier cannot supply, and the diff reads them only from
# the engine side: `keys` (the surrogate keys the entity re-derived to) and `unresolved` (the
# fields where survivorship TIED, with their candidates).
#
# CLASSIFICATION — the point of the harness. Per lane (identity/attribute/edge/media/description):
#
#   :match           both sides agree (counted, never itemized — the report stays readable)
#   :value_mismatch  both hold the field, values differ            -> a mapping/decode gap (gr-be3)
#   :unresolved      the engine tied and has no winner, so it cannot answer what the applier
#                    answered                                      -> a survivorship gap (gr-7yw),
#                                                                      NOT a mapping gap
#   :engine_only     the engine asserts something the applier's product does not carry
#   :applier_only    the applier carries something the engine never claimed -> the dangerous class:
#                                                                      a field the mapping DROPS
#   :cardinality     the engine re-derived the entity to ≠1 surrogate key while the applier has
#                    exactly one product (a merge/split; MigrationDiff explains which)
#
# SELF-COMPARISON. The two committed cohort snapshots are `"produced_by": "engine"` — derived from
# this repo's own fold because no applier export exists here yet. Diffing the engine against them
# is a REGRESSION guard on the fold and executable documentation of the wire shape; it is NOT
# parity evidence. The report says so (`cohort.self_comparison`, and a line in `to_summary/1`).
#
# SCOPE: one case = one applier product plus the legacy history behind it (usually one envelope;
# several when a single product's history spans merged legacy entities). Cross-entity over-merge
# stays MigrationDiff/gr-ose's subject, and the description/media lanes' OWN attributes are their
# own cohorts — here they appear as the product's members, by legacy id.

defmodule ParityHarness do
  @moduledoc """
  Whole-product parity: fold a cohort of legacy histories through the engine and classify every
  divergence from the snapshots medipim's `ProductDeltaApplier` materializes for the same products.

  `snapshot/3` renders the engine side, `compare/2` diffs one pair, `run/2` a whole cohort, and
  `from_dir/2` discovers a cohort on disk (`<stem>.json` + `<stem>.snapshot.json`). See the module
  header for the export contract and the divergence classes.
  """

  @wire_version "1"

  # The set-shaped lanes: {lane, wire field}. Attributes are field/value and handled separately.
  @set_lanes [
    {:identity, "identity"},
    {:edge, "edges"},
    {:media, "media"},
    {:description, "descriptions"}
  ]

  @required_fields ~w(schema_version source_system legacy_entity identity attributes edges media descriptions)

  @empty_counts %{
    match: 0,
    value_mismatch: 0,
    unresolved: 0,
    engine_only: 0,
    applier_only: 0,
    cardinality: 0
  }

  # ── the engine side ──────────────────────────────────────────────────────────

  @doc """
  Materialize one product's legacy history through the engine and render it in the parity wire
  shape (see the module header). `envelopes` is that product's contract-C history — a list, since
  `Rederivation` folds lists, but normally the single envelope of one legacy entity.

  Media and descriptions are reported by the LEGACY ids their sources held (`"158717"`), resolved
  from the lane ledgers, not by the engine's `MED_*`/`DSC_*` surrogate keys — the applier speaks
  legacy ids, and the diff needs one vocabulary.
  """
  def snapshot(envelopes, at \\ 1, priority \\ GoldenRecords.default_priority(), aliases \\ %{})

  def snapshot([%HistoryEnvelope{} = first | _] = envelopes, at, priority, aliases) do
    rederivation = Rederivation.run(envelopes, at)
    %{records: records} = GoldenRecords.project(rederivation, priority, aliases)
    variants = Enum.flat_map(records, & &1.variants)
    ledgers = rederivation.ledgers

    %{
      "schema_version" => @wire_version,
      "produced_by" => "engine",
      "source_system" => first.source_system,
      "legacy_entity" => first.legacy_entity,
      "keys" => variants |> Enum.map(& &1.key) |> Enum.sort(),
      "identity" => members(variants, & &1.codes, &code_string/1),
      "attributes" => attributes(variants, &(&1.status == :resolved), & &1.value),
      "unresolved" => attributes(variants, &(&1.status != :resolved), &candidates/1),
      "edges" => members(variants, & &1.categories, &edge_string/1),
      "media" => members(variants, & &1.media, &legacy_id(&1.asset, ledgers[:media], :asset_id)),
      "descriptions" =>
        members(variants, & &1.descriptions, &legacy_id(&1.key, ledgers[:description], :text_id))
    }
  end

  # ── the diff ─────────────────────────────────────────────────────────────────

  @doc """
  Diff one engine snapshot (from `snapshot/3`) against one applier snapshot, both in the wire
  shape. Returns a JSON-safe case report:

      %{
        legacy_entity: 422156, source_system: "medipim-be",
        keys: ["SK_1"],                  # what the entity re-derived to
        applier_produced_by: "applier",  # "engine" => this case is a self-comparison
        counts: %{match: n, value_mismatch: n, unresolved: n, engine_only: n,
                  applier_only: n, cardinality: n},
        divergences: [%{lane: :attribute, field: "weight", classification: :value_mismatch,
                        engine: 859, applier: 780}, ...],   # :unresolved also carries :candidates
        clean: false
      }

  Matches are counted, not itemized. Divergences are sorted by `{lane, field}`, so two runs of the
  same cohort produce identical reports.
  """
  def compare(engine, applier) do
    {set_matches, set_divergences} =
      Enum.reduce(@set_lanes, {0, []}, fn {lane, field}, {matches, acc} ->
        {n, divergences} = set_lane(lane, wire(engine, field), wire(applier, field))
        {matches + n, acc ++ divergences}
      end)

    {attribute_matches, attribute_divergences} =
      attribute_lane(
        wire(engine, "attributes", %{}),
        wire(engine, "unresolved", %{}),
        wire(applier, "attributes", %{})
      )

    divergences =
      (cardinality(engine) ++ set_divergences ++ attribute_divergences)
      |> Enum.sort_by(&{&1.lane, &1.field})

    %{
      legacy_entity: engine["legacy_entity"] || applier["legacy_entity"],
      source_system: engine["source_system"] || applier["source_system"],
      keys: wire(engine, "keys"),
      applier_produced_by: Map.get(applier, "produced_by", "applier"),
      counts: counts(divergences, set_matches + attribute_matches),
      divergences: divergences,
      clean: divergences == []
    }
  end

  @doc """
  Run a whole cohort. Each case is `%{envelopes: [%HistoryEnvelope{}], applier: <wire map>}`.
  Options: `:at` (the instant to re-derive at, default 1), `:priority` (the survivorship policy
  handed to `GoldenRecords.project/2`, default the permissive one — so ties surface as
  `:unresolved` rather than being decided arbitrarily) and `:aliases` (the dimension-alias map,
  gr-1y5 — so the parity gate exercises the same seam production folds through).

  Returns the cohort report:

      %{
        cases: [<compare/2 report>, ...],
        counts: %{...},                   # the per-class totals across the cohort
        divergences: [<divergence + :legacy_entity>, ...],   # flattened, for triage
        cohort: %{entities: n, clean: n, diverging: n, self_comparison: [entity, ...]}
      }
  """
  def run(cases, opts \\ []) when is_list(cases) do
    at = Keyword.get(opts, :at, 1)
    priority = Keyword.get(opts, :priority, GoldenRecords.default_priority())
    aliases = Keyword.get(opts, :aliases, %{})

    cases =
      Enum.map(cases, fn %{envelopes: envelopes, applier: applier} ->
        compare(snapshot(envelopes, at, priority, aliases), applier)
      end)

    %{
      cases: cases,
      counts: Enum.reduce(cases, @empty_counts, &sum_counts(&1.counts, &2)),
      divergences: Enum.flat_map(cases, &attribute_entity/1),
      cohort: %{
        entities: length(cases),
        clean: Enum.count(cases, & &1.clean),
        diverging: Enum.count(cases, &(not &1.clean)),
        self_comparison: for(c <- cases, c.applier_produced_by == "engine", do: c.legacy_entity)
      }
    }
  end

  @doc """
  Discover a cohort in `dir` and run it: every `<stem>.snapshot.json` is paired with the
  `<stem>.json` envelope beside it, in filename order. Options are `run/2`'s. Raises on a missing
  or malformed file — a cohort that cannot be loaded must never be reported as parity.
  """
  def from_dir(dir, opts \\ []), do: dir |> cohort!() |> run(opts)

  @doc """
  The loaded cases `from_dir/2` would run, so a caller can subset or perturb the cohort first.
  """
  def cohort!(dir) do
    dir
    |> Path.join("*.snapshot.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      envelope = HistoryEnvelope.load!(String.replace_suffix(path, ".snapshot.json", ".json"))
      %{envelopes: [envelope], applier: load_snapshot!(path)}
    end)
  end

  @doc """
  Read one applier snapshot file, refusing anything that is not the wire shape: an unsupported
  `schema_version`, or a missing lane (see the module header for why a missing lane is fatal).
  """
  def load_snapshot!(path) do
    map = path |> File.read!() |> JSON.decode!()

    case {map["schema_version"], Enum.reject(@required_fields, &Map.has_key?(map, &1))} do
      {@wire_version, []} ->
        map

      {@wire_version, missing} ->
        raise ArgumentError, "#{path}: parity snapshot is missing #{Enum.join(missing, ", ")}"

      {version, _} ->
        raise ArgumentError, "#{path}: unsupported parity snapshot schema_version #{inspect(version)}"
    end
  end

  # ── rendering ────────────────────────────────────────────────────────────────

  @doc "The cohort report (`run/2`) as JSON — it is JSON-safe by construction (no tuples)."
  def to_json(report), do: JSON.encode!(report)

  @doc """
  The cohort report as a human summary: the cohort tally, the per-class counts, the loud
  self-comparison caveat when any snapshot was engine-produced, then every divergence itemized —
  that itemized list IS the gr-be3 worklist.
  """
  def to_summary(%{counts: counts, cohort: cohort, divergences: divergences}) do
    header = [
      "Parity — #{cohort.entities} entities: #{cohort.clean} clean, #{cohort.diverging} diverging",
      "  match:          #{counts.match}",
      "  value_mismatch: #{counts.value_mismatch}",
      "  unresolved:     #{counts.unresolved}",
      "  engine_only:    #{counts.engine_only}",
      "  applier_only:   #{counts.applier_only}",
      "  cardinality:    #{counts.cardinality}"
    ]

    caveat =
      case cohort.self_comparison do
        [] ->
          []

        entities ->
          [
            "",
            "! #{length(entities)} snapshot(s) are engine-produced (#{Enum.map_join(entities, ", ", &to_string/1)}):",
            "  those cases are a SELF-COMPARISON — a regression guard, not parity evidence."
          ]
      end

    body =
      case divergences do
        [] -> ["", "No divergences."]
        items -> ["", "Divergences (#{length(items)}):" | Enum.map(items, &divergence_line/1)]
      end

    Enum.join(header ++ caveat ++ body, "\n")
  end

  # ── lanes ────────────────────────────────────────────────────────────────────

  # A set lane: membership only, so a member is either shared or one-sided — never a mismatch.
  defp set_lane(lane, engine, applier) do
    engine = MapSet.new(engine)
    applier = MapSet.new(applier)

    divergences =
      Enum.map(one_sided(engine, applier), &divergence(lane, &1, :engine_only, &1, nil)) ++
        Enum.map(one_sided(applier, engine), &divergence(lane, &1, :applier_only, nil, &1))

    {MapSet.size(MapSet.intersection(engine, applier)), divergences}
  end

  defp one_sided(a, b), do: a |> MapSet.difference(b) |> Enum.sort()

  # The attribute lane, over the union of the fields either side knows about. A field the engine
  # left unresolved is :unresolved whatever the applier holds — the tie is the finding.
  defp attribute_lane(resolved, unresolved, applier) do
    [resolved, unresolved, applier]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&classify_attribute(&1, resolved, unresolved, applier))
    |> Enum.split_with(&(&1 == :match))
    |> then(fn {matches, divergences} -> {length(matches), divergences} end)
  end

  defp classify_attribute(field, resolved, unresolved, applier) do
    engine = Map.fetch(resolved, field)
    value = Map.fetch(applier, field)

    cond do
      Map.has_key?(unresolved, field) ->
        divergence(:attribute, field, :unresolved, nil, unwrap(value), %{candidates: unresolved[field]})

      engine == value ->
        :match

      match?({:ok, _}, engine) and match?({:ok, _}, value) ->
        divergence(:attribute, field, :value_mismatch, unwrap(engine), unwrap(value))

      match?({:ok, _}, engine) ->
        divergence(:attribute, field, :engine_only, unwrap(engine), nil)

      true ->
        divergence(:attribute, field, :applier_only, nil, unwrap(value))
    end
  end

  # A product the engine did not re-derive to exactly one surrogate key cannot be compared 1:1 with
  # the applier's single product row: it merged with another entity, or fragmented (see MigrationDiff).
  defp cardinality(engine) do
    case wire(engine, "keys") do
      [_one] -> []
      keys -> [divergence(:product, "variants", :cardinality, length(keys), 1)]
    end
  end

  # ── snapshot helpers ─────────────────────────────────────────────────────────

  defp members(variants, lane, render) do
    variants |> Enum.flat_map(lane) |> Enum.map(render) |> Enum.uniq() |> Enum.sort()
  end

  defp attributes(variants, keep?, render) do
    for variant <- variants, {field, decision} <- variant.attributes, keep?.(decision), into: %{} do
      {field, render.(decision)}
    end
  end

  defp candidates(decision),
    do: Enum.map(decision.candidates, fn {source, value} -> [to_string(source), value] end)

  # A lane record's surrogate key -> the legacy id its source held ("MED_1" -> "158717"), falling
  # back to the surrogate key for an engine-minted record that never carried a source id.
  defp legacy_id(key, ledger, scheme) do
    ledger.members
    |> Map.get(key, MapSet.new())
    |> Enum.find_value(key, fn {s, value} -> s == scheme and to_string(value) end)
  end

  defp code_string({scheme, value}), do: "#{scheme}:#{value}"
  defp edge_string({collection, member}), do: "#{collection}:#{member}"

  # ── report helpers ───────────────────────────────────────────────────────────

  defp divergence(lane, field, classification, engine, applier, extra \\ %{}) do
    Map.merge(
      %{lane: lane, field: field, classification: classification, engine: engine, applier: applier},
      extra
    )
  end

  defp counts(divergences, matches) do
    Enum.reduce(divergences, %{@empty_counts | match: matches}, fn divergence, counts ->
      Map.update!(counts, divergence.classification, &(&1 + 1))
    end)
  end

  defp sum_counts(counts, acc), do: Map.merge(acc, counts, fn _class, a, b -> a + b end)

  defp attribute_entity(%{legacy_entity: entity, divergences: divergences}),
    do: Enum.map(divergences, &Map.put(&1, :legacy_entity, entity))

  defp divergence_line(divergence) do
    detail =
      case divergence do
        %{classification: :unresolved, candidates: candidates} -> "candidates=#{inspect(candidates)}"
        %{engine: engine, applier: applier} -> "engine=#{inspect(engine)} applier=#{inspect(applier)}"
      end

    "  - #{divergence.legacy_entity} #{divergence.lane}/#{divergence.field}: " <>
      "#{divergence.classification} (#{detail})"
  end

  # Wire reads are total: a lane the caller left out reads as empty rather than crashing the diff.
  # `load_snapshot!/1` is what refuses an incomplete APPLIER file (see the header).
  defp wire(map, field, default \\ []), do: Map.get(map, field) || default

  defp unwrap({:ok, value}), do: value
  defp unwrap(:error), do: nil
end
