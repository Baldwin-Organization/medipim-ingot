# golden_record_stress.exs — stress tests on the shared engine (golden_record_core.ex).
#
#   Run:  mix run golden_record_stress.exs
#
# Answers three questions:
#   ACT 1 — what is the ACTUAL produced end result?         (the golden catalog, as data + JSON)
#   ACT 1 — does it work with MULTIPLE products at once?    (3 products, 4 variants, 3 sources)
#   ACT 2 — two sources claim the SAME id but they are two   (code collision -> steward marks the
#           different products — what happens?                code SHARED -> clean two-product split)

alias GoldenRecord.{Events, Substrate, Priority, Cluster, IdentityLedger, Stewardship, History, Api}

defmodule Stress do
  import Substrate, only: [claim: 5]

  @at ~D[2026-01-01]
  @at1 ~D[2026-02-01]
  @at2 ~D[2026-02-10]

  @priority Priority.new(
              %{
                weight_g: [[:manufacturer], [:supplier], [:marketplace]],
                name: [[:marketplace], [:manufacturer], [:supplier]],
                brand: [[:manufacturer], [:supplier]],
                # color: all three sources equally trusted -> a 3-way disagreement is undecidable
                color: [[:supplier, :manufacturer, :marketplace]],
                product: [[:manufacturer], [:supplier], [:marketplace]]
              },
              [[:manufacturer], [:supplier], [:marketplace]]
            )

  # ── ACT 1 data: three real products, several sources, a few contradictions ──
  defp catalog_claims do
    [
      # Product SH-LAV — two variants (250ml + 500ml)
      claim(:supplier, :identity, %{ref: "S1", codes: [{:gtin, "0111"}, {:upc, "9111"}]}, @at, @at),
      claim(:manufacturer, :identity, %{ref: "M1", codes: [{:gtin, "0111"}]}, @at, @at),
      claim(:supplier, :grouping, %{code: {:gtin, "0111"}, product: {:mpn, "SH-LAV"}}, @at, @at),
      claim(:supplier, :attribute, %{code: {:gtin, "0111"}, field: :weight_g, value: 260}, @at, @at),
      claim(:manufacturer, :attribute, %{code: {:gtin, "0111"}, field: :weight_g, value: 255}, @at, @at),
      claim(:supplier, :attribute, %{code: {:gtin, "0111"}, field: :name, value: "Shampoo"}, @at, @at),
      claim(
        :marketplace,
        :attribute,
        %{code: {:gtin, "0111"}, field: :name, value: "Lavender Shampoo 250ml"},
        @at,
        @at
      ),
      claim(:supplier, :identity, %{ref: "S2", codes: [{:gtin, "0222"}]}, @at, @at),
      claim(:supplier, :grouping, %{code: {:gtin, "0222"}, product: {:mpn, "SH-LAV"}}, @at, @at),
      claim(:supplier, :attribute, %{code: {:gtin, "0222"}, field: :weight_g, value: 520}, @at, @at),
      claim(
        :supplier,
        :attribute,
        %{code: {:gtin, "0222"}, field: :name, value: "Lavender Shampoo 500ml"},
        @at,
        @at
      ),

      # Product TB-MINT — one variant, supplier & manufacturer disagree on weight
      claim(:manufacturer, :identity, %{ref: "M2", codes: [{:gtin, "0333"}]}, @at, @at),
      claim(:manufacturer, :grouping, %{code: {:gtin, "0333"}, product: {:mpn, "TB-MINT"}}, @at, @at),
      claim(
        :manufacturer,
        :attribute,
        %{code: {:gtin, "0333"}, field: :name, value: "Mint Toothbrush"},
        @at,
        @at
      ),
      claim(:manufacturer, :attribute, %{code: {:gtin, "0333"}, field: :weight_g, value: 30}, @at, @at),
      claim(:supplier, :attribute, %{code: {:gtin, "0333"}, field: :weight_g, value: 28}, @at, @at),

      # Product SOAP-OAT — one variant
      claim(:supplier, :identity, %{ref: "S3", codes: [{:gtin, "0444"}, {:upc, "0445"}]}, @at, @at),
      claim(:supplier, :grouping, %{code: {:gtin, "0444"}, product: {:mpn, "SOAP-OAT"}}, @at, @at),
      claim(
        :marketplace,
        :attribute,
        %{code: {:gtin, "0444"}, field: :name, value: "Oat Soap Bar"},
        @at,
        @at
      ),
      claim(:supplier, :attribute, %{code: {:gtin, "0444"}, field: :weight_g, value: 100}, @at, @at)
    ]
  end

  # ── ACT 2 data: gtin:7777 used by TWO sources for TWO different products ──
  # Each item also has a DISTINGUISHING gtin (1000 vs 2000); groupings hang off those.
  defp collision_claims do
    [
      claim(:supplier, :identity, %{ref: "A1", codes: [{:gtin, "7777"}, {:gtin, "1000"}]}, @at1, @at1),
      claim(:manufacturer, :identity, %{ref: "B1", codes: [{:gtin, "7777"}, {:gtin, "2000"}]}, @at1, @at1),
      claim(:supplier, :grouping, %{code: {:gtin, "1000"}, product: {:mpn, "ALPHA"}}, @at1, @at1),
      claim(:manufacturer, :grouping, %{code: {:gtin, "2000"}, product: {:mpn, "BETA"}}, @at1, @at1),
      claim(:supplier, :attribute, %{code: {:gtin, "1000"}, field: :name, value: "Widget A"}, @at1, @at1),
      claim(:manufacturer, :attribute, %{code: {:gtin, "2000"}, field: :name, value: "Gadget B"}, @at1, @at1),
      # a genuinely shared attribute living on the shared code
      claim(:manufacturer, :attribute, %{code: {:gtin, "7777"}, field: :brand, value: "Acme"}, @at1, @at1)
    ]
  end

  # ── ACT 3 data: three sources, ONE variant, three kinds of 3-way contradiction ──
  defp threeway_claims do
    [
      claim(:supplier, :identity, %{ref: "T-s", codes: [{:gtin, "0555"}]}, @at1, @at1),
      claim(:manufacturer, :identity, %{ref: "T-m", codes: [{:gtin, "0555"}]}, @at1, @at1),
      claim(:marketplace, :identity, %{ref: "T-k", codes: [{:gtin, "0555"}]}, @at1, @at1),
      # (a) 3-way VALUE split — priority decides (manufacturer > supplier > marketplace)
      claim(:supplier, :attribute, %{code: {:gtin, "0555"}, field: :weight_g, value: 300}, @at1, @at1),
      claim(:manufacturer, :attribute, %{code: {:gtin, "0555"}, field: :weight_g, value: 305}, @at1, @at1),
      claim(:marketplace, :attribute, %{code: {:gtin, "0555"}, field: :weight_g, value: 310}, @at1, @at1),
      # (b) 3-way TIE — all equally trusted, three values -> undecidable
      claim(:supplier, :attribute, %{code: {:gtin, "0555"}, field: :color, value: "red"}, @at1, @at1),
      claim(:manufacturer, :attribute, %{code: {:gtin, "0555"}, field: :color, value: "blue"}, @at1, @at1),
      claim(:marketplace, :attribute, %{code: {:gtin, "0555"}, field: :color, value: "green"}, @at1, @at1),
      # (c) 3-way GROUPING collision — same code, three different products
      claim(:supplier, :grouping, %{code: {:gtin, "0555"}, product: {:mpn, "GADGET"}}, @at1, @at1),
      claim(:manufacturer, :grouping, %{code: {:gtin, "0555"}, product: {:mpn, "WIDGET"}}, @at1, @at1),
      claim(:marketplace, :grouping, %{code: {:gtin, "0555"}, product: {:mpn, "DOODAD"}}, @at1, @at1)
    ]
  end

  # ── ACT 4 data: media linked BY CODE; a later split must re-home it automatically ──
  defp media_phase1 do
    [
      claim(:supplier, :identity, %{ref: "S-100", codes: [{:gtin, "0111"}, {:upc, "9111"}]}, @at1, @at1),
      claim(:supplier, :grouping, %{code: {:gtin, "0111"}, product: {:mpn, "SH-LAV"}}, @at1, @at1),
      claim(
        :supplier,
        :attribute,
        %{code: {:gtin, "0111"}, field: :name, value: "Lavender Shampoo 250ml"},
        @at1,
        @at1
      ),
      # the packshot is keyed to upc:9111; the front render to gtin:0111
      claim(
        :manufacturer,
        :media,
        %{asset: {:dam, "IMG-PACK"}, target: {:upc, "9111"}, role: :primary, uri: "cdn://pack.jpg"},
        @at1,
        @at1
      ),
      claim(
        :marketplace,
        :media,
        %{asset: {:dam, "IMG-FRONT"}, target: {:gtin, "0111"}, role: :gallery, uri: "cdn://front.jpg"},
        @at1,
        @at1
      )
    ]
  end

  defp media_phase2 do
    [
      claim(:supplier, :identity, %{ref: "S-100", codes: [{:gtin, "0111"}]}, @at2, @at2),
      claim(:marketplace, :identity, %{ref: "M-9", codes: [{:upc, "9111"}]}, @at2, @at2),
      claim(:marketplace, :grouping, %{code: {:upc, "9111"}, product: {:mpn, "SH-MINI"}}, @at2, @at2),
      claim(
        :marketplace,
        :attribute,
        %{code: {:upc, "9111"}, field: :name, value: "Lavender Sample 10ml"},
        @at2,
        @at2
      )
    ]
  end

  def run do
    act1()
    act2()
    act3()
    act4()
  end

  # ════════════════════════════════════════════════════════════════════════════════════════
  defp act1 do
    {c, o} = stamp(catalog_claims(), 1)
    res = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c), @at})
    {res, _o} = stamp(res, o)
    log = c ++ res
    golden = History.now(log, @priority)

    title("ACT 1 · THE ACTUAL END RESULT — golden catalog across MULTIPLE products")
    print_golden(golden)

    title("ACT 1 · the same end result SERIALIZED — what a downstream consumer actually gets")
    IO.puts("  (one JSON document per product)\n")
    Enum.each(to_export(golden), &IO.puts("  " <> JSON.encode!(&1)))
  end

  # ════════════════════════════════════════════════════════════════════════════════════════
  defp act2 do
    # Phase 1 — resolve with NO shared codes: the shared 7777 wrongly bridges two products.
    {c, o} = stamp(collision_claims(), 1)
    live = Substrate.current(c)
    res1 = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, Cluster.variants(live), @at1})
    {res1, o} = stamp(res1, o)
    ledger1 = fold(res1, IdentityLedger.new())
    {flags, o} = stamp(Stewardship.detect_collisions(ledger1.members, live, @at1), o)
    log1 = c ++ res1 ++ flags

    title("ACT 2 · two sources both stamp gtin:7777 — naive resolution MERGES them")
    print_golden(History.now(log1, @priority))
    IO.puts("\n  collision detector:")
    Enum.each(flags, &IO.puts("    " <> describe(&1)))

    # Steward's verdict: these ARE two products; gtin:7777 is legitimately shared.
    {verdict, o} = stamp(Stewardship.mark_shared({:gtin, "7777"}, :alice, @at2), o)
    shared = Stewardship.shared_codes(verdict)

    # Phase 2 — re-resolve with 7777 marked shared (it no longer bridges).
    res2 = IdentityLedger.decide(ledger1, {:reconcile, Cluster.variants(live, shared), shared, @at2})
    {res2, _o} = stamp(res2, o)
    log2 = log1 ++ verdict ++ res2

    title("ACT 2 · steward marks gtin:7777 SHARED — re-resolve splits into TWO products")
    IO.puts("  steward verdict:")
    Enum.each(verdict, &IO.puts("    " <> describe(&1)))
    IO.puts("\n  identity events from the re-resolve:")
    Enum.each(res2, &IO.puts("    " <> describe(&1)))
    IO.puts("")
    print_golden(History.now(log2, @priority))

    title("ACT 2 · the end result SERIALIZED — gtin:7777 now sits on BOTH products, legitimately")
    Enum.each(to_export(History.now(log2, @priority)), &IO.puts("  " <> JSON.encode!(&1)))
  end

  # ════════════════════════════════════════════════════════════════════════════════════════
  defp act3 do
    {c, o} = stamp(threeway_claims(), 1)
    live = Substrate.current(c)
    res = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c), @at1})
    {res, o} = stamp(res, o)
    ledger = fold(res, IdentityLedger.new())

    flags =
      Stewardship.detect(ledger.members, live, @priority, @at1) ++
        Stewardship.detect_collisions(ledger.members, live, @at1)

    {flags, o} = stamp(flags, o)
    log = c ++ res ++ flags

    title("ACT 3 · THREE sources, ONE variant — three flavours of 3-way contradiction")
    IO.puts("  weight = priority decides · color = 3-way tie (undecidable) · product = 3-way collision\n")
    print_golden(History.now(log, @priority))
    IO.puts("\n  stewardship queue:")
    print_queue(Stewardship.queue(log))

    {verdicts, _o} =
      stamp(
        Stewardship.resolve_attribute("SK_1", :color, "blue", :alice, @at2) ++
          Stewardship.resolve_collision("SK_1", {:mpn, "WIDGET"}, :alice, @at2),
        o
      )

    log2 = log ++ verdicts

    title("ACT 3 · after steward verdicts (color := blue, product := WIDGET)")
    print_golden(History.now(log2, @priority))
    IO.puts("\n  stewardship queue:")
    print_queue(Stewardship.queue(log2))
  end

  # ════════════════════════════════════════════════════════════════════════════════════════
  defp act4 do
    {c1, o} = stamp(media_phase1(), 1)
    res1 = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c1), @at1})
    {res1, o} = stamp(res1, o)
    ledger1 = fold(res1, IdentityLedger.new())
    log1 = c1 ++ res1

    title("ACT 4 · media linked BY CODE — both assets land on the merged variant")
    print_golden(History.now(log1, @priority))

    {c2, o} = stamp(media_phase2(), o)
    res2 = IdentityLedger.decide(ledger1, {:reconcile, clusters(c1 ++ c2), @at2})
    {res2, _o} = stamp(res2, o)
    log2 = log1 ++ c2 ++ res2

    title("ACT 4 · a split happens — IMG-PACK (target upc:9111) RE-HOMES, no rewiring")
    IO.puts("  identity events: " <> Enum.map_join(res2, "  ", &describe/1) <> "\n")
    print_golden(History.now(log2, @priority))
  end

  # ── orchestration helpers ──
  defp clusters(claims), do: Cluster.variants(Substrate.current(claims))
  defp fold(events, state), do: Enum.reduce(events, state, &IdentityLedger.evolve(&2, &1))

  defp stamp(events, start),
    do: {Enum.map(Enum.with_index(events, start), fn {e, i} -> %{e | order: i} end), start + length(events)}

  # ── JSON-friendly export (the produced artifact) ──
  defp to_export(products) do
    for %{product: p, variants: vs} <- products do
      %{
        "product" => label(p),
        "variants" =>
          for v <- vs do
            %{
              "surrogate_key" => v.key,
              "codes" => Enum.map(v.codes, &label/1),
              "product_status" => to_string(v.product.status),
              "attributes" =>
                Map.new(v.attributes, fn {f, d} ->
                  {to_string(f),
                   %{"value" => d.value, "source" => to_string(d.winner), "status" => to_string(d.status)}}
                end),
              "media" =>
                Enum.map(v.media, fn m ->
                  %{"asset" => label(m.asset), "role" => to_string(m.role), "uri" => m.uri}
                end)
            }
          end
      }
    end
  end

  defp label({s, c}), do: "#{s}:#{c}"

  # ── presentation ──
  defp title(t), do: IO.puts("\n" <> String.duplicate("─", 100) <> "\n  " <> t <> "\n")
  defp pad(x, n), do: String.pad_trailing(to_string(x), n)
  defp listcodes(list), do: Enum.map_join(list, ", ", &label/1)
  defp codes(set), do: set |> MapSet.to_list() |> Enum.sort() |> Enum.map_join(", ", &label/1)
  defp val({_, _} = c), do: label(c)
  defp val(v) when is_binary(v), do: ~s("#{v}")
  defp val(v), do: to_string(v)

  defp describe(%Events.IdentityMinted{} = e), do: "MINT    #{e.key}  {#{codes(e.codes)}}"

  defp describe(%Events.IdentitySplit{} = e),
    do:
      "SPLIT   #{e.key} keeps {#{codes(e.kept_codes)}}, spins off " <>
        Enum.map_join(e.into, ", ", fn {k, c} -> "#{k}{#{codes(c)}}" end)

  defp describe(%Events.IdentityMembersChanged{} = e), do: "MEMBERS #{e.key}  -> {#{codes(e.codes)}}"

  defp describe(%Events.ConflictFlagged{subject: {:collision, key}} = e) do
    prods =
      e.candidates |> Enum.map(fn %{source: s, product: p} -> "#{s}->#{label(p)}" end) |> Enum.join(", ")

    "FLAG    collision on #{key}: grouping points at >1 product (#{prods})"
  end

  defp describe(%Events.ConflictResolved{subject: {:code, c}, decision: :shared, by: by}),
    do: "SHARED  #{label(c)} declared legitimately shared (by #{by})"

  defp describe(other), do: inspect(other)

  defp print_queue(queue) do
    Enum.each(queue, fn {flag, verdict} ->
      subject =
        case flag.subject do
          {:attr, key, dim} -> "#{key}.#{dim}"
          {:collision, key} -> "collision #{key}"
          {:merge, keys} -> "merge #{Enum.join(keys, " + ")}"
        end

      status =
        case verdict do
          nil -> "OPEN"
          %{decision: {:pick, v}, by: by} -> "resolved := #{val(v)} (by #{by})"
          %{decision: {:product, p}, by: by} -> "-> product #{val(p)} (by #{by})"
          %{decision: d, by: by} -> "#{String.upcase(to_string(d))} (by #{by})"
        end

      IO.puts("    #{pad(subject, 22)} flagged #{flag.recorded_at}  ->  #{status}")
    end)
  end

  defp print_golden(products) do
    Enum.each(products, fn %{product: product, variants: variants} ->
      IO.puts("    PRODUCT  #{val(product)}")

      Enum.each(variants, fn v ->
        IO.puts("      variant #{v.key}   [#{listcodes(v.codes)}]")
        print_product_line(v.product)

        Enum.each(v.attributes, fn {field, d} ->
          mark =
            case d.status do
              :needs_review -> "  <-- NEEDS REVIEW"
              :resolved_by_steward -> "  (by steward)"
              _ -> ""
            end

          IO.puts("        #{pad(field, 9)}= #{pad(val(d.value), 28)} (#{d.winner})#{mark}")

          if length(d.candidates) > 1,
            do:
              IO.puts(
                "          claims: " <> Enum.map_join(d.candidates, ", ", fn {s, x} -> "#{s}=#{val(x)}" end)
              )
        end)

        Enum.each(v.media, fn m ->
          IO.puts("        media    : #{pad(label(m.asset), 14)} #{pad(m.role, 8)} #{m.uri}  (#{m.source})")
        end)
      end)
    end)
  end

  defp print_product_line(%{status: :resolved}), do: :ok

  defp print_product_line(%{value: v, winner: w, status: status, candidates: cands}) do
    note = if status == :needs_review, do: "CONTESTED", else: "by steward"

    extra =
      if cands == [],
        do: "",
        else: " — claims: " <> Enum.map_join(cands, ", ", fn {s, p} -> "#{s}->#{val(p)}" end)

    IO.puts("        product  = #{pad(val(v), 28)} (#{w})  <-- #{note}#{extra}")
  end
end

Stress.run()

# ── ACT 3 — scale (GH #57): a generated log measures where the pure fold's ceiling falls, ──────
# and demonstrates fold-once vs refold-per-call on the read path. The Postgres-backed api/
# read models are the production answer; this keeps the ceiling measured instead of guessed.
defmodule Scale do
  import Substrate, only: [claim: 5]

  @at ~D[2026-01-01]
  # generous: this asserts "does not fall over", not a perf regression gate.
  @budget_ms 60_000

  def run(sizes \\ [1_000, 10_000]) do
    IO.puts("\n== ACT 3 — scale: the pure fold, measured ==")
    Enum.each(sizes, &measure/1)
  end

  defp measure(n) do
    claims = generate(n)
    priority = Priority.new(%{}, [])

    {reconcile_us, events} =
      :timer.tc(fn ->
        clusters = Cluster.variants(Substrate.current(claims))
        IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters, @at})
      end)

    events = events |> Enum.with_index(length(claims)) |> Enum.map(fn {e, i} -> %{e | order: i} end)
    log = claims ++ events

    {projection_us, projection} = :timer.tc(fn -> History.now(log, priority) end)
    {members_us, members} = :timer.tc(fn -> Api.members(log) end)

    # The read-path ceiling: 50 lookups against the raw log (refolds per call) vs against the
    # prebuilt members map (folds once).
    codes = for i <- 1..50, do: {:cnk, cnk(i)}
    {per_call_us, _} = :timer.tc(fn -> Enum.each(codes, &Api.resolve_key(log, &1)) end)
    {fold_once_us, _} = :timer.tc(fn -> Enum.each(codes, &Api.resolve_key(members, &1)) end)

    variants = projection |> Enum.flat_map(& &1.variants) |> length()
    total_ms = div(reconcile_us + projection_us + members_us, 1000)

    IO.puts(
      "  #{n} listings -> #{variants} variants: reconcile #{ms(reconcile_us)}, projection #{ms(projection_us)}, " <>
        "ledger #{ms(members_us)}, 50 lookups raw-log #{ms(per_call_us)} vs fold-once #{ms(fold_once_us)}"
    )

    if total_ms > @budget_ms do
      raise "scale ceiling blown: #{n} listings took #{total_ms}ms (budget #{@budget_ms}ms)"
    end

    if variants != n do
      raise "scale fold lost listings: expected #{n} variants, got #{variants}"
    end
  end

  # One listing = identity + grouping + one attribute, on a unique national code (no bridges —
  # this measures fold/projection cost, not cluster pathology).
  defp generate(n) do
    1..n
    |> Enum.flat_map(fn i ->
      code = {:cnk, cnk(i)}

      [
        claim(:supplier, :identity, %{ref: "S#{i}", codes: [code]}, @at, @at),
        claim(:supplier, :grouping, %{code: code, product: {:mpn, "P#{i}"}}, @at, @at),
        claim(:supplier, :attribute, %{code: code, field: :name, value: "Product #{i}"}, @at, @at)
      ]
    end)
    |> Enum.with_index()
    |> Enum.map(fn {c, i} -> %{c | order: i} end)
  end

  defp cnk(i), do: to_string(1_000_000 + i)

  defp ms(us), do: "#{Float.round(us / 1000, 1)}ms"
end

Scale.run()
