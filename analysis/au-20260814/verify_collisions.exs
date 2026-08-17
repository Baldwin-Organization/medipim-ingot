# verify_collisions.exs — engine-verify the 587 AU cross-entity GTIN collisions (gr-sx7.2).
#
# The streaming dupes.py scan (au_collisions.json) is an UPPER BOUND: it cannot attribute
# `set NULL` to a code and it knows nothing about shared-code marking or merge gating. This
# script gets the exact per-code verdict by folding each collision group's entities TOGETHER
# through the real pipeline (gen.exs decode -> ClaimMapping -> Rederivation -> LegacyXref):
#
#   * merged          — the group's entities re-derive to ONE key by a TRUSTED bridge:
#                       genuine duplicate listings, engine merges them.
#   * merged_suspect  — merged, but the bridge is barcode-grade only (gr-ose) — flagged
#                       ConflictFlagged/:suspect, the review queue proper.
#   * shared          — entities stay separate keys and the code sits on >1 of them (the
#                       engine carried it shared without fusing).
#   * single_owner    — history dissolves the collision: exactly one final key holds the code.
#   * not_live        — the code survives on NO key (the scan's upper-bound artifact).
#
# Entities that resolve to nothing (the end-of-life/replacement lifecycle, gr-sx7.4) are
# counted per group as `dead_entities`.
#
# Usage (raw per-entity dumps extracted from the CSV first — see the bead comment). Args come in
# as env vars because gen.exs self-runs on a non-empty System.argv():
#   AU_RAW_DIR=<raw_dir> AU_OUT=<out_json> mix run analysis/au-20260814/verify_collisions.exs

raw_dir = System.fetch_env!("AU_RAW_DIR")
out_path = System.fetch_env!("AU_OUT")

Code.require_file(Path.join(__DIR__, "../../test/ingest/fixtures/gen.exs"))

at = Date.diff(~D[2026-08-14], ~D[1970-01-01]) * 86_400

collisions =
  __DIR__ |> Path.join("au_collisions.json") |> File.read!() |> JSON.decode!()

# {:gtin, "09315..."} from "gtin:09315..."
parse_code = fn str ->
  [scheme, value] = String.split(str, ":", parts: 2)
  {CodeRegistry.engine_scheme(scheme), value}
end

# ── connected components over the collision graph (an entity can sit in several codes) ────────
find = fn find, parent, x ->
  case Map.get(parent, x, x) do
    ^x -> x
    p -> find.(find, parent, p)
  end
end

parent =
  for {_code, ents} <- collisions, [a | rest] = Enum.sort(ents), b <- rest, reduce: %{} do
    acc ->
      ra = find.(find, acc, a)
      rb = find.(find, acc, b)
      if ra == rb, do: acc, else: Map.put(acc, rb, ra)
  end

components =
  collisions
  |> Enum.group_by(fn {_code, ents} -> find.(find, parent, hd(Enum.sort(ents))) end)
  |> Map.values()

IO.puts(:stderr, "#{map_size(collisions)} codes in #{length(components)} components")

# Silence the oracle's per-entity summary chatter.
run_quiet = fn fun ->
  {:ok, dev} = StringIO.open("")
  old = Process.group_leader()
  Process.group_leader(self(), dev)

  try do
    fun.()
  after
    Process.group_leader(self(), old)
    StringIO.close(dev)
  end
end

decode = fn ent ->
  raw = Path.join(raw_dir, "medipim_au_#{ent}.raw.jsonl")
  out = Path.join(raw_dir, "medipim_au_#{ent}.json")
  run_quiet.(fn -> Gen.run("medipim-au", ent, raw, out) end)
  HistoryEnvelope.load!(out)
end

verdicts =
  components
  |> Task.async_stream(
    fn group ->
      ents = group |> Enum.flat_map(fn {_c, es} -> es end) |> Enum.uniq() |> Enum.sort()
      envs = Enum.map(ents, decode)
      red = Rederivation.run(envs, at)
      xref = LegacyXref.build(red)

      resolved =
        Map.new(ents, fn e ->
          {e,
           case LegacyXref.resolve_legacy(xref, e) do
             {:ok, key, rel} -> {key, rel}
             {:error, :unknown_legacy} -> {nil, :unknown}
           end}
        end)

      members = Lanes.partition_members(red.ledger.members).product

      primary_of = fn e -> elem(Map.fetch!(resolved, e), 0) end
      rel_of = fn e -> elem(Map.fetch!(resolved, e), 1) end
      merged_rel? = fn e -> match?({:merged, _}, rel_of.(e)) or match?({:merged, _, _}, rel_of.(e)) end

      rel_str = fn
        :stable -> "stable"
        :unknown -> "unknown"
        {:split, _} -> "split"
        {:merged, _} -> "merged"
        {:merged, _, :suspect} -> "merged_suspect"
      end

      for {code_str, code_ents} <- group do
        code = parse_code.(code_str)
        owners = for {k, codes} <- members, MapSet.member?(codes, code), do: k
        dead = Enum.count(code_ents, &match?({nil, :unknown}, Map.fetch!(resolved, &1)))

        # The verdict is decided by the RELATION the xref hands back, not by counting keys:
        # a split (a shared artgId spanning two keys) must not read as a merge.
        verdict =
          cond do
            owners == [] ->
              "not_live"

            length(owners) > 1 ->
              "shared"

            true ->
              [owner] = owners
              into = Enum.filter(code_ents, &(primary_of.(&1) == owner and merged_rel?.(&1)))

              cond do
                length(into) > 1 and Enum.any?(into, &match?({:merged, _, :suspect}, rel_of.(&1))) ->
                  "merged_suspect"

                length(into) > 1 ->
                  "merged"

                true ->
                  "single_owner"
              end
          end

        %{
          code: code_str,
          entities: code_ents,
          verdict: verdict,
          relations: Map.new(code_ents, &{&1, rel_str.(rel_of.(&1))}),
          dead_entities: dead
        }
      end
    end,
    max_concurrency: System.schedulers_online(),
    timeout: 600_000
  )
  |> Enum.flat_map(fn {:ok, vs} -> vs end)

histogram = verdicts |> Enum.group_by(& &1.verdict) |> Map.new(fn {k, v} -> {k, length(v)} end)

File.write!(out_path, JSON.encode!(%{histogram: histogram, verdicts: Enum.sort_by(verdicts, & &1.code)}))
IO.puts("verdicts: #{inspect(histogram)}")
IO.puts("wrote #{out_path}")
