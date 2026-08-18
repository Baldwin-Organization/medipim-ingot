# golden_record_api.exs — the customer-facing layer over the engine (golden_record_core.ex):
#   1. ATC collections   — classify a product into categories; watch membership re-home on a split
#   2. CNK public identity — two sources, two CNKs, one product -> canonical + alias, resolve by either
#   3. The read API       — resolve by code, identity status, a merge redirect, the change feed
#
#   Run:  mix run golden_record_api.exs

alias GoldenRecord.{Events, Substrate, Priority, Cluster, IdentityLedger, Stewardship, History, Api, PublicId}

defmodule ApiDemo do
  import Substrate, only: [claim: 5]

  @d1 ~D[2026-01-10]
  @d2 ~D[2026-02-01]

  @priority Priority.new(
              %{cnk: [[:manufacturer], [:wholesaler]], product: [[:manufacturer], [:supplier]]},
              [[:manufacturer], [:supplier], [:wholesaler]]
            )

  def run do
    collections()
    cnk()
    api()
  end

  # ════════════════════════════════════════════════════════════════════════════════════════
  defp collections do
    phase1 = [
      claim(:supplier, :identity, %{ref: "S", codes: [{:gtin, "0111"}, {:upc, "9111"}]}, @d1, @d1),
      claim(:who, :member_of, %{member_code: {:gtin, "0111"}, collection: {:atc, "A10"}}, @d1, @d1),
      claim(:who, :member_of, %{member_code: {:upc, "9111"}, collection: {:atc, "A10BA02"}}, @d1, @d1)
    ]

    {c1, o} = stamp(phase1, 1)
    res1 = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c1), @d1})
    {res1, o} = stamp(res1, o)
    ledger1 = fold(res1, IdentityLedger.new())

    title("1. ATC COLLECTIONS — classification is edges-by-code, so it re-homes on a split")
    IO.puts("  before the split:")
    print_categories(History.now(c1 ++ res1, @priority))

    phase2 = [
      claim(:supplier, :identity, %{ref: "S", codes: [{:gtin, "0111"}]}, @d2, @d2),
      claim(:marketplace, :identity, %{ref: "M", codes: [{:upc, "9111"}]}, @d2, @d2)
    ]

    {c2, o} = stamp(phase2, o)
    res2 = IdentityLedger.decide(ledger1, {:reconcile, clusters(c1 ++ c2), @d2})
    {res2, _} = stamp(res2, o)

    IO.puts("\n  after upc:9111 splits off — the A10BA02 membership followed the code:")
    print_categories(History.now(c1 ++ res1 ++ c2 ++ res2, @priority))
  end

  # ════════════════════════════════════════════════════════════════════════════════════════
  defp cnk do
    {log, _} =
      build([
        claim(:manufacturer, :identity, %{ref: "A", codes: [{:cnk, "0111"}, {:gtin, "5001"}]}, @d1, @d1),
        claim(:wholesaler, :identity, %{ref: "B", codes: [{:cnk, "0222"}, {:gtin, "5001"}]}, @d1, @d1)
      ])

    key = Api.resolve_key(log, {:gtin, "5001"})
    %{canonical: canon, aliases: aliases} = PublicId.canonical(:cnk, key, log, @priority)

    title("2. CNK PUBLIC IDENTITY — two sources gave two CNKs for the same product")
    IO.puts("  surrogate key (internal) : #{key}")
    IO.puts("  canonical CNK (by priority): #{lc(canon)}")
    IO.puts("  alias CNKs                : #{Enum.map_join(aliases, ", ", &lc/1)}")

    IO.puts(
      "  lookup by the ALIAS cnk:0222 -> resolves to #{Api.resolve_key(log, {:cnk, "0222"})} (same product)"
    )

    IO.puts("  identity-grade uniqueness check: #{inspect(PublicId.collisions(:cnk, log))}")
  end

  # ════════════════════════════════════════════════════════════════════════════════════════
  defp api do
    {log, ledger} =
      build([
        claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0111"}]}, @d1, @d1),
        claim(:supplier, :identity, %{ref: "B", codes: [{:gtin, "0222"}]}, @d1, @d1)
      ])

    title("3. THE READ API — resolve by code, identity status, redirects, change feed")
    {:ok, hit} = Api.lookup(log, {:gtin, "0111"}, @priority)
    IO.puts("  GET /resolve?gtin=0111  -> key #{hit.key}, identity #{inspect(hit.identity)}")

    # a steward approves merging SK_2 into SK_1
    merge =
      ledger.members
      |> then(&Stewardship.approve_merge(&1, ["SK_1", "SK_2"], :alice, @d2))
      |> Enum.with_index(length(log) + 1)
      |> Enum.map(fn {e, i} -> %{e | order: i} end)

    log2 = log ++ merge

    IO.puts("\n  (steward approves merge SK_1 + SK_2 -> SK_1)\n")
    IO.puts("  GET /product/SK_2       -> #{inspect(Api.identity_status(log2, "SK_2"))}  (301 redirect)")

    IO.puts(
      "  GET /resolve?gtin=0222  -> key #{Api.resolve_key(log2, {:gtin, "0222"})}  (code still lands correctly)"
    )

    feed = Api.changes_since(log2, length(log))
    IO.puts("\n  change feed since cursor #{length(log)}:")
    Enum.each(feed, &IO.puts("    " <> describe(&1)))
  end

  # ── helpers ──
  defp build(claims) do
    {c, o} = stamp(claims, 1)
    res = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c), @d1})
    {res, _} = stamp(res, o)
    {c ++ res, fold(res, IdentityLedger.new())}
  end

  defp stamp(events, start),
    do: {Enum.map(Enum.with_index(events, start), fn {e, i} -> %{e | order: i} end), start + length(events)}

  defp fold(events, state), do: Enum.reduce(events, state, &IdentityLedger.evolve(&2, &1))
  defp clusters(c, shared \\ MapSet.new()), do: Cluster.variants(Substrate.current(c), shared)

  defp title(t), do: IO.puts("\n" <> String.duplicate("─", 100) <> "\n  " <> t <> "\n")
  defp lc({s, c}), do: "#{s}:#{c}"

  defp print_categories(golden) do
    golden
    |> Enum.flat_map(& &1.variants)
    |> Enum.each(fn v ->
      IO.puts(
        "    variant #{v.key} [#{Enum.map_join(v.codes, ", ", &lc/1)}]  categories: #{Enum.map_join(v.categories, ", ", &lc/1)}"
      )
    end)
  end

  defp describe(%Events.IdentitiesMerged{from: f, into: i}), do: "MERGE   #{Enum.join(f, " + ")} -> #{i}"
  defp describe(%Events.IdentityMembersChanged{key: k}), do: "MEMBERS #{k} changed"
  defp describe(other), do: inspect(other)
end

ApiDemo.run()
