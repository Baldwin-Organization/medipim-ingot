# golden_record_ddd.exs — DDD + event-sourced demo (engine lives in lib/golden_record_core.ex).
#
#   Run:  mix run golden_record_ddd.exs
#
# Shows: an append-only event log as system of record; golden as a fold; transaction-time and
# valid-time travel; conflict events (attribute tie + a gated identity merge); steward verdicts.

alias GoldenRecord.{Events, Substrate, Priority, Cluster, IdentityLedger, Stewardship, History}

defmodule Demo do
  import Substrate, only: [claim: 5]

  @jan5 ~D[2026-01-05]
  @d1 ~D[2026-01-10]
  @d2 ~D[2026-02-01]
  @d3 ~D[2026-02-15]
  @now ~D[2026-03-01]

  @priority Priority.new(
              %{
                weight_g: [[:manufacturer], [:supplier, :marketplace]],
                name: [[:marketplace], [:manufacturer], [:supplier]],
                product: [[:manufacturer], [:supplier], [:marketplace]]
              },
              [[:manufacturer], [:supplier], [:marketplace]]
            )

  defp run1 do
    [
      claim(:supplier, :identity, %{ref: "S-100", codes: [{:gtin, "0111"}, {:upc, "9111"}]}, @d1, @d1),
      claim(:manufacturer, :identity, %{ref: "MF-1", codes: [{:gtin, "0111"}]}, @d1, @d1),
      claim(:supplier, :identity, %{ref: "S-101", codes: [{:gtin, "0222"}]}, @d1, @d1),
      claim(:supplier, :grouping, %{code: {:gtin, "0111"}, product: {:mpn, "SH-LAV"}}, @d1, @d1),
      claim(:supplier, :grouping, %{code: {:gtin, "0222"}, product: {:mpn, "SH-LAV"}}, @d1, @d1),
      claim(:supplier, :attribute, %{code: {:gtin, "0111"}, field: :weight_g, value: 260}, @d1, @d1),
      claim(:manufacturer, :attribute, %{code: {:gtin, "0111"}, field: :weight_g, value: 255}, @d1, @d1),
      claim(:supplier, :attribute, %{code: {:gtin, "0111"}, field: :name, value: "Shampoo 250"}, @d1, @d1),
      claim(
        :marketplace,
        :attribute,
        %{code: {:gtin, "0111"}, field: :name, value: "Brand X Lavender Shampoo 250ml"},
        @d1,
        @d1
      ),
      claim(:supplier, :attribute, %{code: {:gtin, "0222"}, field: :weight_g, value: 520}, @d1, @d1),
      claim(:marketplace, :attribute, %{code: {:gtin, "0222"}, field: :weight_g, value: 525}, @d1, @d1),
      claim(:supplier, :attribute, %{code: {:gtin, "0222"}, field: :name, value: "Shampoo 500"}, @d1, @d1)
    ]
  end

  defp run2 do
    [
      claim(
        :manufacturer,
        :attribute,
        %{code: {:gtin, "0111"}, field: :weight_g, value: 250},
        ~D[2026-01-01],
        @d2
      ),
      claim(:supplier, :identity, %{ref: "S-100", codes: [{:gtin, "0111"}]}, @d2, @d2),
      claim(:marketplace, :identity, %{ref: "M-9", codes: [{:upc, "9111"}]}, @d2, @d2),
      claim(:marketplace, :grouping, %{code: {:upc, "9111"}, product: {:mpn, "SH-MINI"}}, @d2, @d2),
      claim(
        :marketplace,
        :attribute,
        %{code: {:upc, "9111"}, field: :name, value: "Lavender Sample 10ml"},
        @d2,
        @d2
      )
    ]
  end

  defp run3 do
    [claim(:scraper, :identity, %{ref: "X-1", codes: [{:gtin, "0111"}, {:gtin, "0222"}]}, @d3, @d3)]
  end

  def run do
    {c1, o} = stamp(run1(), 1)
    res1 = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c1), @d1})
    {res1, o} = stamp(res1, o)
    ledger1 = fold(res1, IdentityLedger.new())
    {flags1, o} = stamp(Stewardship.detect(ledger1.members, Substrate.current(c1), @priority, @d1), o)

    {c2, o} = stamp(run2(), o)
    res2 = IdentityLedger.decide(ledger1, {:reconcile, clusters(c1 ++ c2), @d2})
    {res2, o} = stamp(res2, o)
    ledger2 = fold(res2, ledger1)
    {verdict_attr, o} = stamp(Stewardship.resolve_attribute("SK_2", :weight_g, 520, :alice, @d2), o)

    {c3, o} = stamp(run3(), o)
    res3 = IdentityLedger.decide(ledger2, {:reconcile, clusters(c1 ++ c2 ++ c3), @d3})
    {res3, o} = stamp(res3, o)
    {verdict_merge, _o} = stamp(Stewardship.reject_merge(["SK_1", "SK_2"], :alice, @d3), o)

    log = c1 ++ res1 ++ flags1 ++ c2 ++ res2 ++ verdict_attr ++ c3 ++ res3 ++ verdict_merge

    title("THE EVENT LOG  (append-only; system of record)  —  rec = recorded_at, val = valid_from")
    Enum.each(log, &IO.puts("    " <> describe(&1)))

    title("GOLDEN NOW  (fold the whole log)")
    print_golden(History.project_as_of(log, @now, @priority))

    title("STEWARDSHIP QUEUE  (every conflict + its verdict, from the log)")
    print_queue(Stewardship.queue(log))

    title("HISTORY · transaction-time — GOLDEN AS WE BELIEVED IT ON #{@d1}")
    print_golden(History.project_as_of(log, @d1, @priority))

    title("HISTORY · bitemporal — weight of gtin:0111 across both clocks")
    print_bitemporal_grid(log)

    title("HISTORY · lineage of SK_1 — 'why did this identity change?'")
    Enum.each(History.lineage(log, "SK_1"), &IO.puts("    " <> describe(&1)))

    replayed = fold(log, IdentityLedger.new()).members

    IO.puts(
      "\n    (replay check: #{if replayed == ledger2.members, do: "ok — fold(log) == live ledger", else: "MISMATCH"})"
    )
  end

  defp clusters(claims), do: Cluster.variants(Substrate.current(claims))
  defp fold(events, state), do: Enum.reduce(events, state, &IdentityLedger.evolve(&2, &1))

  defp stamp(events, start),
    do: {Enum.map(Enum.with_index(events, start), fn {e, i} -> %{e | order: i} end), start + length(events)}

  # ── presentation ──
  defp title(t), do: IO.puts("\n" <> String.duplicate("─", 100) <> "\n  " <> t <> "\n")
  defp pad(x, n), do: String.pad_trailing(to_string(x), n)
  defp code({s, c}), do: "#{s}:#{c}"
  defp codes(set), do: set |> MapSet.to_list() |> Enum.sort() |> Enum.map_join(", ", &code/1)
  defp listcodes(list), do: Enum.map_join(list, ", ", &code/1)
  defp val({_, _} = c), do: code(c)
  defp val(v) when is_binary(v), do: ~s("#{v}")
  defp val(v), do: to_string(v)
  defp pairs(list), do: Enum.map_join(list, ", ", fn {s, x} -> "#{s}=#{val(x)}" end)

  defp clock(%Events.ClaimAsserted{recorded_at: r, valid_from: v}), do: "rec #{r}  val #{v}"
  defp clock(%{recorded_at: r}), do: "rec #{r}             "

  defp describe(%Events.ClaimAsserted{kind: :identity, source: s, data: %{ref: r, codes: cs}} = e),
    do: "##{pad(e.order, 3)} #{clock(e)}  CLAIM   #{pad(s, 12)} identity #{pad(r, 6)}= {#{listcodes(cs)}}"

  defp describe(%Events.ClaimAsserted{kind: :grouping, source: s, data: %{code: c, product: p}} = e),
    do: "##{pad(e.order, 3)} #{clock(e)}  CLAIM   #{pad(s, 12)} group    #{pad(code(c), 10)}-> #{code(p)}"

  defp describe(%Events.ClaimAsserted{kind: :attribute, source: s, data: %{code: c, field: f, value: v}} = e),
    do:
      "##{pad(e.order, 3)} #{clock(e)}  CLAIM   #{pad(s, 12)} attr     #{pad(code(c), 10)}.  #{pad(f, 8)}= #{val(v)}"

  defp describe(%Events.IdentityMinted{} = e),
    do: "##{pad(e.order, 3)} #{clock(e)}  MINT    #{e.key}  {#{codes(e.codes)}}"

  defp describe(%Events.IdentityMembersChanged{} = e),
    do: "##{pad(e.order, 3)} #{clock(e)}  MEMBERS #{e.key}  -> {#{codes(e.codes)}}"

  defp describe(%Events.IdentitiesMerged{} = e),
    do: "##{pad(e.order, 3)} #{clock(e)}  MERGE   #{Enum.join(e.from, " + ")} -> #{e.into}"

  defp describe(%Events.IdentitySplit{} = e),
    do:
      "##{pad(e.order, 3)} #{clock(e)}  SPLIT   #{e.key} keeps {#{codes(e.kept_codes)}}, spins off " <>
        Enum.map_join(e.into, ", ", fn {k, c} -> "#{k}{#{codes(c)}}" end)

  defp describe(%Events.ConflictFlagged{subject: {:attr, key, dim}} = e),
    do: "##{pad(e.order, 3)} #{clock(e)}  FLAG    #{key}.#{dim} undecidable: #{pairs(e.candidates)}"

  defp describe(%Events.ConflictFlagged{subject: {:merge, keys}} = e),
    do:
      "##{pad(e.order, 3)} #{clock(e)}  FLAG    merge? #{Enum.join(keys, " + ")} bridged by {#{codes(e.candidates)}} — HELD for review"

  defp describe(%Events.ConflictResolved{subject: {:attr, key, dim}, decision: {:pick, v}, by: by} = e),
    do: "##{pad(e.order, 3)} #{clock(e)}  RESOLVE #{key}.#{dim} := #{val(v)} (by #{by})"

  defp describe(%Events.ConflictResolved{subject: {:merge, keys}, decision: d, by: by} = e),
    do:
      "##{pad(e.order, 3)} #{clock(e)}  RESOLVE merge #{Enum.join(keys, " + ")} #{String.upcase(to_string(d))} (by #{by})"

  defp print_queue(queue) do
    Enum.each(queue, fn {flag, verdict} ->
      subject =
        case flag.subject do
          {:attr, key, dim} -> "#{key}.#{dim}"
          {:merge, keys} -> "merge #{Enum.join(keys, " + ")}"
          {:collision, key} -> "collision #{key}"
        end

      status =
        case verdict do
          nil -> "OPEN"
          %{decision: {:pick, v}, by: by} -> "resolved := #{val(v)} (by #{by})"
          %{decision: d, by: by} -> "#{String.upcase(to_string(d))} (by #{by})"
        end

      IO.puts("    #{pad(subject, 26)} flagged #{flag.recorded_at}  ->  #{status}")
    end)
  end

  defp print_golden(products) do
    Enum.each(products, fn %{product: product, variants: variants} ->
      IO.puts("    PRODUCT  #{val(product)}")

      Enum.each(variants, fn v ->
        IO.puts("      variant #{v.key}   [#{listcodes(v.codes)}]")

        Enum.each(v.attributes, fn {field, d} ->
          mark =
            case d.status do
              :needs_review -> "  <-- NEEDS REVIEW (priority tie)"
              :resolved_by_steward -> "  (resolved by steward)"
              _ -> ""
            end

          IO.puts("        #{pad(field, 9)}= #{pad(val(d.value), 34)} (#{d.winner})#{mark}")
        end)
      end)
    end)
  end

  defp print_bitemporal_grid(log) do
    knowns = [@jan5, @d1, @now]
    effs = [@jan5, @d1, @now]
    IO.puts("                         effective →   " <> Enum.map_join(effs, "   ", &pad(&1, 10)))

    Enum.each(knowns, fn k ->
      cells = Enum.map_join(effs, "   ", fn e -> pad(grid_cell(log, k, e), 10) end)
      IO.puts("    as-known #{k}  :   #{cells}")
    end)

    IO.puts(
      "\n    (rows = what we KNEW by that date · cols = what was TRUE on that date · '—' = unknown/not-yet-effective)"
    )
  end

  defp grid_cell(log, as_known, effective_on) do
    History.project_bitemporal(log, as_known, effective_on, @priority)
    |> Enum.flat_map(& &1.variants)
    |> Enum.find(fn v -> {:gtin, "0111"} in v.codes end)
    |> case do
      nil ->
        "—"

      v ->
        case List.keyfind(v.attributes, :weight_g, 0) do
          {_, d} -> val(d.value)
          nil -> "—"
        end
    end
  end
end

Demo.run()
