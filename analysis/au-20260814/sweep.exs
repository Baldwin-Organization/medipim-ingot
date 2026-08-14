# sweep.exs — AU cohort quality sweep: decode (gen.exs oracle) -> Temporal fold -> LegacyXref
# -> per-entity quality metrics -> aggregate report (JSON).
Code.require_file("test/ingest/fixtures/gen.exs")

scratch = "/private/tmp/claude-501/-Users-wardvanhooreweghe-workspace-ingot/efe31553-a87e-4c59-a781-30b5c24290a7/scratchpad"
raw_dir = Path.join(scratch, "au_raw")
env_dir = Path.join(scratch, "au_env")
File.mkdir_p!(env_dir)

at = ~D[2026-08-14]

entities =
  raw_dir
  |> File.ls!()
  |> Enum.map(fn f -> f |> String.replace_prefix("medipim_au_", "") |> String.replace_suffix(".raw.jsonl", "") |> String.to_integer() end)
  |> Enum.sort()

IO.puts(:stderr, "sweeping #{length(entities)} entities…")

# Silence the oracle's per-entity summary chatter by capturing stdout per task.
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

results =
  entities
  |> Task.async_stream(
    fn ent ->
      raw = Path.join(raw_dir, "medipim_au_#{ent}.raw.jsonl")
      out = Path.join(env_dir, "medipim_au_#{ent}.json")

      try do
        run_quiet.(fn -> Gen.run("medipim-au", ent, raw, out) end)
        env = HistoryEnvelope.load!(out)
        t = Temporal.run([env])

        merge_flags =
          for %Events.ConflictFlagged{subject: {:merge, ks}} = e <- t.log, do: {e.recorded_at, Enum.sort(ks)}

        retracts = Enum.count(t.log, &match?(%Events.IdentityRetracted{}, &1))
        splits = Enum.count(t.log, &match?(%Events.IdentitySplit{}, &1))
        merges = Enum.count(t.log, &match?(%Events.IdentitiesMerged{}, &1))

        product_keys = Lanes.partition_members(t.ledger.members).product

        r = Rederivation.run([env], at)
        xref = LegacyXref.build(r)

        relation =
          case LegacyXref.resolve_legacy(xref, ent) do
            {:ok, _k, rel} -> rel
            {:error, _} -> :unknown
          end

        golden = Temporal.golden_as_of(t.log, at)

        {review_fields, tie_sources} =
          for %{variants: vs} <- golden, v <- vs, {field, d} <- v.attributes, d.status == :needs_review, reduce: {[], []} do
            {fs, ss} -> {[field | fs], Enum.map(d.candidates, &elem(&1, 0)) ++ ss}
          end

        %{
          entity: ent,
          ok: true,
          deltas: length(env.events),
          keys: map_size(product_keys),
          relation: relation,
          merge_flag_dates: merge_flags |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length(),
          merge_open: merge_flags != [] and map_size(product_keys) > 1,
          retracts: retracts,
          splits: splits,
          merges: merges,
          review_fields: Enum.uniq(review_fields),
          tie_sources: Enum.uniq(tie_sources)
        }
      rescue
        e -> %{entity: ent, ok: false, error: Exception.format(:error, e) |> String.slice(0, 200)}
      end
    end,
    max_concurrency: System.schedulers_online(),
    timeout: 300_000,
    on_timeout: :kill_task
  )
  |> Enum.map(fn
    {:ok, res} -> res
    {:exit, reason} -> %{entity: nil, ok: false, error: "task exit: #{inspect(reason)}"}
  end)

{ok, failed} = Enum.split_with(results, & &1.ok)

summary = %{
  cohort: length(results),
  decode_or_fold_failures: length(failed),
  by_relation: ok |> Enum.frequencies_by(& &1.relation),
  multi_key_entities: Enum.count(ok, &(&1.keys > 1)),
  open_merge_flags: Enum.count(ok, & &1.merge_open),
  with_retracts: Enum.count(ok, &(&1.retracts > 0)),
  with_splits: Enum.count(ok, &(&1.splits > 0)),
  with_review_fields: Enum.count(ok, &(&1.review_fields != [])),
  review_field_histogram:
    ok |> Enum.flat_map(& &1.review_fields) |> Enum.frequencies() |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(20) |> Enum.map(fn {k, v} -> [to_string(k), v] end),
  tie_source_histogram:
    ok |> Enum.flat_map(& &1.tie_sources) |> Enum.frequencies() |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(20) |> Enum.map(fn {k, v} -> [to_string(k), v] end),
  worst:
    ok
    |> Enum.sort_by(&(-(&1.keys + &1.retracts + length(&1.review_fields) + if(&1.merge_open, do: 5, else: 0))))
    |> Enum.take(20)
}

File.write!(Path.join(scratch, "au_quality.json"), JSON.encode!(%{summary: Map.drop(summary, [:worst]), worst: summary.worst, entities: ok, failed: failed}))

IO.puts(:stderr, "\n== SUMMARY ==")
IO.puts(:stderr, inspect(Map.drop(summary, [:worst]), pretty: true, limit: :infinity))
IO.puts(:stderr, "\n== WORST 20 ==")
Enum.each(summary.worst, fn w ->
  IO.puts(
    :stderr,
    "  #{w.entity}: keys=#{w.keys} rel=#{w.relation} merge_open=#{w.merge_open} flags=#{w.merge_flag_dates} retracts=#{w.retracts} review=#{inspect(w.review_fields) |> String.slice(0, 80)}"
  )
end)

Enum.each(Enum.take(failed, 5), fn f -> IO.puts(:stderr, "FAIL #{f.entity}: #{f[:error]}") end)
