# test/demo_export_test.exs — the story demo can't lie (bead gr-0cj).
#
# demo_export.exs drives the real engine through the story scenes and serializes snapshots for
# the viz. This suite replays the same scenarios through the same engine calls and asserts each
# beat the demo's narration depends on. If the engine stops behaving like the story says, this
# fails — the demo cannot silently drift from engine behaviour.

alias GoldenRecord.{Events, Substrate, Priority, Cluster, IdentityLedger, Stewardship, History}

defmodule DemoExportTest do
  use ExUnit.Case, async: true
  import Substrate, only: [claim: 5]

  @ga {:gtin, "05410013100072"}
  @ka {:cnk, "1234567"}
  @gb {:gtin, "08712345678906"}
  @kb {:cnk, "7654321"}

  defp stamp(entries, start),
    do:
      {entries |> Enum.with_index(start) |> Enum.map(fn {e, i} -> %{e | order: i} end),
       start + length(entries)}

  defp fold(events, ledger), do: Enum.reduce(events, ledger, &IdentityLedger.evolve(&2, &1))

  defp reconcile(log, ledger, d) do
    live = log |> Enum.filter(&match?(%Events.ClaimAsserted{}, &1)) |> Substrate.current()
    IdentityLedger.decide(ledger, {:reconcile, Cluster.variants(live), d})
  end

  defp variants(golden), do: Enum.flat_map(golden, & &1.variants)
  defp find_variant(golden, code), do: Enum.find(variants(golden), &(code in &1.codes))
  defp attr(variant, field), do: variant.attributes |> List.keyfind(field, 0) |> elem(1)

  defp detect(ledger, log, priority, d) do
    live = log |> Enum.filter(&match?(%Events.ClaimAsserted{}, &1)) |> Substrate.current()
    Stewardship.detect(ledger.members, live, priority, d)
  end

  describe "the mistake-is-cheap scene (story chapter 6)" do
    @priority Priority.new(%{weight_g: [[:acme, :bolt]]}, [[:acme], [:bolt]])
    @d1 ~D[2026-04-01]
    @d2 ~D[2026-04-15]
    @d3 ~D[2026-05-02]

    defp two_products do
      claims = [
        claim(:acme, :identity, %{ref: "ACME-SUN", codes: [@ga, @ka]}, @d1, @d1),
        claim(:acme, :attribute, %{code: @ga, field: :weight_g, value: 250}, @d1, @d1),
        claim(
          :acme,
          :media,
          %{asset: {:dam, "IMG-A"}, target: @ga, role: :primary, uri: "cdn://a"},
          @d1,
          @d1
        ),
        claim(:bolt, :identity, %{ref: "BOLT-2114", codes: [@gb, @kb]}, @d1, @d1),
        claim(:bolt, :attribute, %{code: @gb, field: :weight_g, value: 480}, @d1, @d1),
        claim(:bolt, :media, %{asset: {:dam, "IMG-B"}, target: @gb, role: :primary, uri: "cdn://b"}, @d1, @d1)
      ]

      {claims, o} = stamp(claims, 0)
      {events, o} = reconcile(claims, IdentityLedger.new(), @d1) |> stamp(o)
      {claims ++ events, fold(events, IdentityLedger.new()), o}
    end

    test "beat 1 — two distinct products, two keys, no conflicts" do
      {log, ledger, _} = two_products()
      assert Map.keys(ledger.members) |> Enum.sort() == ["SK_1", "SK_2"]
      assert detect(ledger, log, @priority, @d1) == []
    end

    test "beat 2+3 — the approved (wrong) merge fuses the keys AND surfaces the weight contradiction" do
      {log, ledger, o} = two_products()
      {merge, _} = Stewardship.approve_merge(ledger.members, ["SK_1", "SK_2"], :sam, @d2) |> stamp(o)
      ledger2 = fold(merge, ledger)
      log2 = log ++ merge

      assert [%{variants: [fused]}] = History.now(log2, @priority)
      assert Enum.all?([@ga, @ka, @gb, @kb], &(&1 in fused.codes))

      # the evidence was never destroyed — both weights survive, and their tie is flagged
      assert [%Events.ConflictFlagged{subject: {:attr, "SK_1", :weight_g}, candidates: candidates}] =
               detect(ledger2, log2, @priority, @d2)

      assert Enum.sort(candidates) == [acme: 250, bolt: 480]
    end

    test "beats 4+5 — the split heals: keys re-partition, attributes and media re-home, queue empties" do
      {log, ledger, o} = two_products()
      {merge, o} = Stewardship.approve_merge(ledger.members, ["SK_1", "SK_2"], :sam, @d2) |> stamp(o)
      ledger2 = fold(merge, ledger)

      {split, _} = Stewardship.split(ledger2, "SK_1", [[@gb, @kb]], :sam, @d3) |> stamp(o)
      ledger3 = fold(split, ledger2)
      log3 = log ++ merge ++ split

      assert ledger3.members == %{
               "SK_1" => MapSet.new([@ga, @ka]),
               "SK_3" => MapSet.new([@gb, @kb])
             }

      golden = History.now(log3, @priority)
      a = find_variant(golden, @ga)
      b = find_variant(golden, @gb)
      assert {a.key, b.key} == {"SK_1", "SK_3"}
      assert attr(a, :weight_g) == %{attr(a, :weight_g) | value: 250, status: :resolved}
      assert attr(b, :weight_g).value == 480
      assert [%{asset: {:dam, "IMG-A"}}] = a.media
      assert [%{asset: {:dam, "IMG-B"}}] = b.media

      # nothing left for the steward — the contradiction existed only inside the wrong merge
      assert detect(ledger3, log3, @priority, @d3) == []

      # and the whole arc is in the lineage: merge, split, and who decided
      lineage = History.lineage(log3, "SK_1")
      assert Enum.any?(lineage, &match?(%Events.IdentitiesMerged{}, &1))
      assert Enum.any?(lineage, &match?(%Events.IdentitySplit{}, &1))
      assert Enum.any?(lineage, &match?(%Events.ConflictResolved{subject: {:split, "SK_1"}, by: :sam}, &1))
    end
  end

  describe "the priority scene (story chapter 3)" do
    @prio Priority.new(
            %{color: [[:manufacturer, :supplier], [:marketplace]]},
            [[:manufacturer], [:supplier], [:marketplace]]
          )
    @t ~D[2026-03-01]

    defp weight_claims(entries) do
      claims =
        [
          claim(:manufacturer, :identity, %{ref: "M", codes: [@ga]}, @t, @t),
          claim(:supplier, :identity, %{ref: "S", codes: [@ga]}, @t, @t),
          claim(:marketplace, :identity, %{ref: "K", codes: [@ga]}, @t, @t)
        ] ++
          Enum.map(entries, fn {src, field, value} ->
            claim(src, :attribute, %{code: @ga, field: field, value: value}, @t, @t)
          end)

      {claims, o} = stamp(claims, 0)
      {events, _} = reconcile(claims, IdentityLedger.new(), @t) |> stamp(o)
      claims ++ events
    end

    test "each better-ranked source takes the field over; candidates keep the full ranking" do
      log = weight_claims([{:marketplace, :weight_g, 300}])
      assert [%{variants: [v]}] = History.now(log, @prio)
      assert attr(v, :weight_g).value == 300

      log = weight_claims([{:marketplace, :weight_g, 300}, {:supplier, :weight_g, 260}])
      assert [%{variants: [v]}] = History.now(log, @prio)
      assert %{value: 260, winner: :supplier} = attr(v, :weight_g)

      log =
        weight_claims([
          {:marketplace, :weight_g, 300},
          {:supplier, :weight_g, 260},
          {:manufacturer, :weight_g, 250}
        ])

      assert [%{variants: [v]}] = History.now(log, @prio)
      decision = attr(v, :weight_g)
      assert %{value: 250, winner: :manufacturer, status: :resolved} = decision
      assert Keyword.keys(decision.candidates) == [:manufacturer, :supplier, :marketplace]
    end

    test "a top-tier tie is honestly undecidable -> flagged; a steward pick resolves it" do
      log = weight_claims([{:manufacturer, :color, "white"}, {:supplier, :color, "ivory"}])
      assert [%{variants: [v]}] = History.now(log, @prio)
      assert attr(v, :color).status == :needs_review

      {pick, _} = Stewardship.resolve_attribute("SK_1", :color, "ivory", :sam, @t) |> stamp(length(log))
      assert [%{variants: [v]}] = History.now(log ++ pick, @prio)
      assert %{value: "ivory", winner: "steward:sam", status: :resolved_by_steward} = attr(v, :color)
    end
  end
end
