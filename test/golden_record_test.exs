# golden_record_test.exs — ExUnit suite for the engine (golden_record_core.ex).
#
#   Run:  mix test
#
# Engine modules are compiled from lib/; ExUnit is started in test/test_helper.exs.

alias GoldenRecord.{
  Events,
  Codes,
  Substrate,
  Priority,
  Cluster,
  IdentityLedger,
  Stewardship,
  History,
  Api,
  PublicId
}

defmodule CodesTest do
  use ExUnit.Case, async: true

  describe "GTIN canonicalization (EAN 8-14 are one scheme at different widths)" do
    test "EAN-13 zero-fills to a 14-digit GTIN" do
      assert Codes.canonicalize({:ean, "5012345678900"}) == {:gtin, "05012345678900"}
    end

    test "UPC-12 and its EAN-13 form are the same trade item" do
      assert Codes.same?({:upc, "036000291452"}, {:ean, "0036000291452"})
    end

    test "EAN-8 zero-fills to 14 (its own allocation, padded — never derived from a longer code)" do
      assert Codes.canonicalize({:ean, "96385074"}) == {:gtin, "00000096385074"}
    end

    test "a GTIN-8 and that same value zero-padded to 12 are the SAME key (no need to 'set it to 8')" do
      assert Codes.same?({:gtin, "96385074"}, {:gtin, "000096385074"})
    end

    test "schemes unify: a UPC and its GTIN-14 form collapse to one (scheme :gtin)" do
      assert Codes.canonicalize({:upc, "036000291452"}) == {:gtin, "00036000291452"}
    end

    test "non-GTIN schemes pass through untouched" do
      assert Codes.canonicalize({:cnk, "3216547"}) == {:cnk, "3216547"}
    end

    test "non-GTIN-length numeric values pass through untouched (toy codes stay put)" do
      assert Codes.canonicalize({:gtin, "0111"}) == {:gtin, "0111"}
    end
  end

  describe "national short-code padding (medipim zero-pads to a fixed width)" do
    test "cip_acl7 left-pads an all-digit value to 7" do
      assert Codes.canonicalize({:cip_acl7, "44813"}) == {:cip_acl7, "0044813"}
    end

    test "a full-width cip_acl7 is untouched (real medipim data is already 7 wide)" do
      assert Codes.canonicalize({:cip_acl7, "4440813"}) == {:cip_acl7, "4440813"}
    end

    test "pzn left-pads to 8; cn to 6" do
      assert Codes.canonicalize({:pzn, "12345"}) == {:pzn, "00012345"}
      assert Codes.canonicalize({:cn, "1234"}) == {:cn, "001234"}
    end

    test "a non-digit national value is NOT padded (only all-digit codes pad)" do
      assert Codes.canonicalize({:cip_acl7, "AB"}) == {:cip_acl7, "AB"}
    end

    test "cnk is deliberately pass-through — short fake cnks must stay as-is" do
      assert Codes.canonicalize({:cnk, "111"}) == {:cnk, "111"}
      assert Codes.canonicalize({:cnk, "0111"}) == {:cnk, "0111"}
    end
  end

  describe "check-digit validation" do
    test "valid GTIN-13 and GTIN-8 pass" do
      assert Codes.valid_gtin?({:ean, "4006381333931"})
      assert Codes.valid_gtin?({:ean, "96385074"})
    end

    test "a transposed/typo'd check digit is rejected" do
      refute Codes.valid_gtin?({:ean, "4006381333930"})
    end

    test "valid constructed GTIN-14 case code passes" do
      assert Codes.valid_gtin?({:gtin, "15012345678907"})
    end
  end

  describe "GS1 structure" do
    test "indicator digit: 0 = base unit, 1 = a packaging level" do
      assert Codes.indicator({:ean, "5012345678900"}) == 0
      assert Codes.indicator({:gtin, "15012345678907"}) == 1
    end

    test "restricted-distribution prefixes (02, 20-29) are flagged, normal ones are not" do
      assert Codes.restricted?({:gtin, "2012345678905"})
      refute Codes.restricted?({:ean, "5012345678900"})
    end
  end

  describe "real-world codes" do
    test "EAN-13 4057598014359 is valid and zero-fills to indicator-0 (the base unit)" do
      assert Codes.valid_gtin?({:ean, "4057598014359"})
      assert Codes.canonicalize({:ean, "4057598014359"}) == {:gtin, "04057598014359"}
      assert Codes.indicator({:ean, "4057598014359"}) == 0
    end

    test "GTIN-14 24057598014353 is valid and carries indicator 2 (a packaging level)" do
      assert Codes.valid_gtin?({:gtin, "24057598014353"})
      assert Codes.indicator({:gtin, "24057598014353"}) == 2
    end

    test "the GTIN-14 is NOT the padded EAN-13 — different indicator means a different trade item" do
      # they share the same item body but sit at different packaging levels, so they must NOT merge
      refute Codes.same?({:ean, "4057598014359"}, {:gtin, "24057598014353"})
      # the true 14-digit form of the base unit is indicator 0, not 2:
      assert Codes.canonicalize({:ean, "4057598014359"}) == {:gtin, "04057598014359"}
    end
  end
end

defmodule EngineTest do
  use ExUnit.Case, async: true
  import Substrate, only: [claim: 5]

  @d1 ~D[2026-01-10]
  @d2 ~D[2026-02-01]

  @priority Priority.new(
              %{
                weight_g: [[:manufacturer], [:supplier], [:marketplace]],
                color: [[:supplier, :manufacturer, :marketplace]],
                product: [[:manufacturer], [:supplier], [:marketplace]],
                cnk: [[:manufacturer], [:supplier]]
              },
              [[:manufacturer], [:supplier], [:marketplace]]
            )

  # ── helpers ──
  defp stamp(events, start),
    do: {Enum.map(Enum.with_index(events, start), fn {e, i} -> %{e | order: i} end), start + length(events)}

  defp fold(events, state), do: Enum.reduce(events, state, &IdentityLedger.evolve(&2, &1))
  defp clusters(c, shared \\ MapSet.new()), do: Cluster.variants(Substrate.current(c), shared)

  # single resolution pass -> {log, ledger}
  defp resolve(claims, at \\ @d1) do
    {c, o} = stamp(claims, 1)
    res = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c), at})
    {res, _} = stamp(res, o)
    {c ++ res, fold(res, IdentityLedger.new())}
  end

  defp steward_merge(log, ledger, at \\ @d2) do
    keys = ledger.members |> Map.keys() |> Enum.sort()
    start = log |> Enum.map(& &1.order) |> Enum.max(fn -> 0 end) |> Kernel.+(1)
    {events, _next} = Stewardship.approve_merge(ledger.members, keys, :steward, at) |> stamp(start)
    {log ++ events, fold(events, ledger)}
  end

  defp variants(golden), do: Enum.flat_map(golden, & &1.variants)
  defp find_variant(golden, code), do: Enum.find(variants(golden), &(code in &1.codes))
  defp attr(variant, field), do: variant.attributes |> List.keyfind(field, 0) |> elem(1)

  describe "identity resolution" do
    test "two sources sharing a code merge into one variant" do
      {log, _} =
        resolve([
          claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0111"}, {:upc, "9111"}]}, @d1, @d1),
          claim(:manufacturer, :identity, %{ref: "B", codes: [{:gtin, "0111"}]}, @d1, @d1)
        ])

      assert [variant] = variants(History.now(log, @priority))
      assert {:gtin, "0111"} in variant.codes
      assert {:upc, "9111"} in variant.codes
    end

    test "equivalent EAN/GTIN representations from two sources resolve to ONE variant" do
      {log, _} =
        resolve([
          claim(:supplier, :identity, %{ref: "A", codes: [{:ean, "5012345678900"}]}, @d1, @d1),
          claim(:manufacturer, :identity, %{ref: "B", codes: [{:gtin, "05012345678900"}]}, @d1, @d1)
        ])

      assert [variant] = variants(History.now(log, @priority))
      assert variant.codes == [{:gtin, "05012345678900"}]
    end
  end

  describe "survivorship" do
    test "the highest-priority source wins a contradicted field" do
      {log, _} =
        resolve([
          claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0111"}]}, @d1, @d1),
          claim(:supplier, :attribute, %{code: {:gtin, "0111"}, field: :weight_g, value: 260}, @d1, @d1),
          claim(:manufacturer, :attribute, %{code: {:gtin, "0111"}, field: :weight_g, value: 255}, @d1, @d1)
        ])

      d = History.now(log, @priority) |> find_variant({:gtin, "0111"}) |> attr(:weight_g)
      assert d.value == 255
      assert d.winner == :manufacturer
      assert d.status == :resolved
    end

    test "a 3-way tie among equally-trusted sources is undecidable -> needs_review" do
      {log, _} =
        resolve([
          claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0555"}]}, @d1, @d1),
          claim(:supplier, :attribute, %{code: {:gtin, "0555"}, field: :color, value: "red"}, @d1, @d1),
          claim(:manufacturer, :attribute, %{code: {:gtin, "0555"}, field: :color, value: "blue"}, @d1, @d1),
          claim(:marketplace, :attribute, %{code: {:gtin, "0555"}, field: :color, value: "green"}, @d1, @d1)
        ])

      d = History.now(log, @priority) |> find_variant({:gtin, "0555"}) |> attr(:color)
      assert d.status == :needs_review
      assert length(d.candidates) == 3
    end
  end

  describe "code collisions" do
    test "a variant whose grouping points at >1 product is flagged and marked contested" do
      claims = [
        claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0777"}]}, @d1, @d1),
        claim(:supplier, :grouping, %{code: {:gtin, "0777"}, product: {:mpn, "ALPHA"}}, @d1, @d1),
        claim(:manufacturer, :grouping, %{code: {:gtin, "0777"}, product: {:mpn, "BETA"}}, @d1, @d1)
      ]

      {log, ledger} = resolve(claims)
      flags = Stewardship.detect_collisions(ledger.members, Substrate.current(claims), @d1)

      assert [%Events.ConflictFlagged{subject: {:collision, _}}] = flags
      variant = History.now(log, @priority) |> find_variant({:gtin, "0777"})
      assert variant.product.status == :needs_review
    end
  end

  describe "the steward merge gate" do
    test "a bridge across two established keys is PROPOSED, not auto-merged" do
      {c1, o} =
        stamp(
          [
            claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0111"}]}, @d1, @d1),
            claim(:supplier, :identity, %{ref: "B", codes: [{:gtin, "0222"}]}, @d1, @d1)
          ],
          1
        )

      res1 = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c1), @d1})
      {res1, o} = stamp(res1, o)
      ledger1 = fold(res1, IdentityLedger.new())

      {c2, o} =
        stamp(
          [claim(:scraper, :identity, %{ref: "X", codes: [{:gtin, "0111"}, {:gtin, "0222"}]}, @d2, @d2)],
          o
        )

      res2 = IdentityLedger.decide(ledger1, {:reconcile, clusters(c1 ++ c2), @d2})
      {res2, _} = stamp(res2, o)
      ledger2 = fold(res2, ledger1)

      assert Enum.any?(res2, &match?(%Events.ConflictFlagged{subject: {:merge, _}}, &1))
      assert map_size(ledger2.members) == 2, "the merge must NOT have been applied automatically"
    end

    # gr-bb7: merging established keys is FOUR-EYES — the decision function itself refuses a
    # single steward acting alone, no router or UI involved.
    test "endorse_merge: first steward proposes, the same steward is refused, a second fuses" do
      members = %{"SK_1" => MapSet.new([{:gtin, "0111"}]), "SK_2" => MapSet.new([{:gtin, "0222"}])}

      # the first endorsement records a proposal (with its reason) — nothing fuses
      assert {:proposed, [proposal]} =
               Stewardship.endorse_merge(members, ["SK_2", "SK_1"], nil, :alice, @d2, "same product")

      assert %Events.MergeProposed{keys: ["SK_1", "SK_2"], by: :alice, reason: "same product"} = proposal

      # the SAME steward approving their own proposal is refused by the engine
      assert {:error, :four_eyes} =
               Stewardship.endorse_merge(members, ["SK_1", "SK_2"], proposal, :alice, @d2)

      # a DIFFERENT steward supplies the second pair of eyes — the merge events fire,
      # and the decision records who approved and why
      assert {:ok, events} =
               Stewardship.endorse_merge(members, ["SK_1", "SK_2"], proposal, :bob, @d2, "verified GTINs")

      assert Enum.any?(events, &match?(%Events.IdentitiesMerged{into: "SK_1"}, &1))

      assert Enum.any?(
               events,
               &match?(%Events.ConflictResolved{decision: :approved, by: :bob, reason: "verified GTINs"}, &1)
             )
    end
  end

  describe "shared codes" do
    test "marking a code shared makes it non-bridging -> the wrongly-merged variant splits in two" do
      claims = [
        claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "7777"}, {:gtin, "1000"}]}, @d1, @d1),
        claim(:manufacturer, :identity, %{ref: "B", codes: [{:gtin, "7777"}, {:gtin, "2000"}]}, @d1, @d1)
      ]

      {c, o} = stamp(claims, 1)
      res1 = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c), @d1})
      {res1, _} = stamp(res1, o)
      ledger1 = fold(res1, IdentityLedger.new())
      assert map_size(ledger1.members) == 1, "without the share, 7777 wrongly bridges them"

      shared = Stewardship.shared_codes(Stewardship.mark_shared({:gtin, "7777"}, :alice, @d2))

      res2 =
        IdentityLedger.decide(
          ledger1,
          {:reconcile, Cluster.variants(Substrate.current(c), shared), shared, @d2}
        )

      ledger2 = fold(res2, ledger1)

      assert map_size(ledger2.members) == 2

      assert Enum.all?(Map.values(ledger2.members), &MapSet.member?(&1, {:gtin, "7777"})),
             "both resulting variants legitimately carry the shared code"
    end
  end

  describe "media re-homes by code" do
    test "an asset linked to a code follows that code through a split" do
      phase1 = [
        claim(:supplier, :identity, %{ref: "S", codes: [{:gtin, "0111"}, {:upc, "9111"}]}, @d1, @d1),
        claim(:supplier, :grouping, %{code: {:gtin, "0111"}, product: {:mpn, "P1"}}, @d1, @d1),
        claim(
          :manufacturer,
          :media,
          %{asset: {:dam, "IMG"}, target: {:upc, "9111"}, role: :primary, uri: "cdn://x"},
          @d1,
          @d1
        )
      ]

      {c1, o} = stamp(phase1, 1)
      res1 = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c1), @d1})
      {res1, o} = stamp(res1, o)
      ledger1 = fold(res1, IdentityLedger.new())

      phase2 = [
        claim(:supplier, :identity, %{ref: "S", codes: [{:gtin, "0111"}]}, @d2, @d2),
        claim(:marketplace, :identity, %{ref: "M", codes: [{:upc, "9111"}]}, @d2, @d2),
        claim(:marketplace, :grouping, %{code: {:upc, "9111"}, product: {:mpn, "P2"}}, @d2, @d2)
      ]

      {c2, o} = stamp(phase2, o)
      res2 = IdentityLedger.decide(ledger1, {:reconcile, clusters(c1 ++ c2), @d2})
      {res2, _} = stamp(res2, o)
      golden = History.now(c1 ++ res1 ++ c2 ++ res2, @priority)

      with_9111 = find_variant(golden, {:upc, "9111"})
      with_0111 = find_variant(golden, {:gtin, "0111"})
      assert Enum.any?(with_9111.media, &(&1.asset == {:dam, "IMG"})), "media followed upc:9111"
      assert with_0111.media == [], "and is no longer on the gtin:0111 variant"
    end
  end

  describe "history" do
    test "transaction-time travel shows the old belief; a superseding claim changes 'now'" do
      claims = [
        claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0111"}]}, @d1, @d1),
        claim(:manufacturer, :attribute, %{code: {:gtin, "0111"}, field: :weight_g, value: 255}, @d1, @d1),
        # back-dated correction: effective Jan 1, but only recorded on @d2
        claim(
          :manufacturer,
          :attribute,
          %{code: {:gtin, "0111"}, field: :weight_g, value: 250},
          ~D[2026-01-01],
          @d2
        )
      ]

      {log, _} = resolve(claims)

      as_of_d1 =
        History.project_as_of(log, @d1, @priority) |> find_variant({:gtin, "0111"}) |> attr(:weight_g)

      now = History.now(log, @priority) |> find_variant({:gtin, "0111"}) |> attr(:weight_g)
      assert as_of_d1.value == 255
      assert now.value == 250
    end

    test "the live ledger is exactly the fold of the log (event-sourcing invariant)" do
      {log, ledger} =
        resolve([
          claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0111"}]}, @d1, @d1),
          claim(:supplier, :identity, %{ref: "B", codes: [{:gtin, "0222"}]}, @d1, @d1)
        ])

      assert fold(log, IdentityLedger.new()).members == ledger.members
    end
  end

  describe "collections (ATC classification)" do
    test "a variant lists its collections, and membership re-homes on a split" do
      phase1 = [
        claim(:supplier, :identity, %{ref: "S", codes: [{:gtin, "0111"}, {:upc, "9111"}]}, @d1, @d1),
        claim(:who, :member_of, %{member_code: {:gtin, "0111"}, collection: {:atc, "A10"}}, @d1, @d1),
        claim(:who, :member_of, %{member_code: {:upc, "9111"}, collection: {:atc, "A10BA02"}}, @d1, @d1)
      ]

      {c1, o} = stamp(phase1, 1)
      res1 = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c1), @d1})
      {res1, o} = stamp(res1, o)
      ledger1 = fold(res1, IdentityLedger.new())

      before = History.now(c1 ++ res1, @priority) |> find_variant({:gtin, "0111"})
      assert before.categories == [{:atc, "A10"}, {:atc, "A10BA02"}]

      phase2 = [
        claim(:supplier, :identity, %{ref: "S", codes: [{:gtin, "0111"}]}, @d2, @d2),
        claim(:marketplace, :identity, %{ref: "M", codes: [{:upc, "9111"}]}, @d2, @d2)
      ]

      {c2, o} = stamp(phase2, o)
      res2 = IdentityLedger.decide(ledger1, {:reconcile, clusters(c1 ++ c2), @d2})
      {res2, _} = stamp(res2, o)
      golden = History.now(c1 ++ res1 ++ c2 ++ res2, @priority)

      assert find_variant(golden, {:gtin, "0111"}).categories == [{:atc, "A10"}]
      assert find_variant(golden, {:upc, "9111"}).categories == [{:atc, "A10BA02"}]
    end
  end

  describe "customer API (resolve by code, redirects, change feed)" do
    test "lookup by code lands on the current owner and reports an active identity" do
      {log, _} =
        resolve([claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0111"}]}, @d1, @d1)])

      assert {:ok, %{identity: %{status: :active}, variant: v}} = Api.lookup(log, {:gtin, "0111"}, @priority)
      assert {:gtin, "0111"} in v.codes
    end

    test "a merged key redirects to its survivor; the code resolves to the survivor" do
      {log, ledger} =
        resolve([
          claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0111"}]}, @d1, @d1),
          claim(:supplier, :identity, %{ref: "B", codes: [{:gtin, "0222"}]}, @d1, @d1)
        ])

      merge =
        ledger.members
        |> then(&Stewardship.approve_merge(&1, ["SK_1", "SK_2"], :alice, @d2))
        |> Enum.with_index(length(log) + 1)
        |> Enum.map(fn {e, i} -> %{e | order: i} end)

      log2 = log ++ merge
      assert Api.identity_status(log2, "SK_2") == %{status: :merged, superseded_by: "SK_1"}
      assert Api.resolve_key(log2, {:gtin, "0222"}) == "SK_1"
    end

    test "a chained merge redirects to the final survivor, not the intermediate key" do
      log = [
        %Events.IdentitiesMerged{from: ["SK_A", "SK_B"], into: "SK_B", recorded_at: @d2, order: 1},
        %Events.IdentitiesMerged{from: ["SK_B", "SK_C"], into: "SK_C", recorded_at: @d2, order: 2}
      ]

      assert Api.identity_status(log, "SK_A") == %{status: :merged, superseded_by: "SK_C"}
      assert Api.identity_status(log, "SK_B") == %{status: :merged, superseded_by: "SK_C"}
      assert Api.identity_status(log, "SK_C") == %{status: :active}
    end

    test "the change feed returns identity events after a cursor" do
      {log, _} =
        resolve([claim(:supplier, :identity, %{ref: "A", codes: [{:gtin, "0111"}]}, @d1, @d1)])

      changes = Api.changes_since(log, 0)
      assert Enum.any?(changes, &match?(%Events.IdentityMinted{}, &1))
      assert Api.changes_since(log, 999) == []
    end
  end

  describe "CNK identity-grade (canonical id + aliases)" do
    test "two sources, two CNKs, same product -> canonical by priority + alias, resolvable by either" do
      {log, ledger} =
        resolve([
          claim(:manufacturer, :identity, %{ref: "A", codes: [{:cnk, "0111"}, {:gtin, "5001"}]}, @d1, @d1),
          claim(:supplier, :identity, %{ref: "B", codes: [{:cnk, "0222"}, {:gtin, "5001"}]}, @d1, @d1)
        ])

      # The automatic guard keeps these apart because the shared barcode contradicts the two CNKs.
      # A reviewed merge is the explicit positive evidence that allows both ids on one key.
      assert map_size(ledger.members) == 2
      {log, ledger} = steward_merge(log, ledger)

      live = log |> Enum.filter(&match?(%Events.ClaimAsserted{}, &1)) |> Substrate.current()
      replay = IdentityLedger.decide(ledger, {:reconcile, Cluster.variants(live), @d2})
      refute Enum.any?(replay, &match?(%Events.IdentitySplit{}, &1))
      assert map_size(fold(replay, ledger).members) == 1

      key = Api.resolve_key(log, {:gtin, "5001"})
      result = PublicId.canonical(:cnk, key, log, @priority)
      assert result.canonical == {:cnk, "0111"}, "manufacturer outranks supplier for :cnk"
      assert result.aliases == [{:cnk, "0222"}]
      # a customer can look up by the alias and still land on the same product
      assert Api.resolve_key(log, {:cnk, "0222"}) == key
    end

    test "equally trusted sources with different CNKs expose candidates, not a fake canonical id" do
      claims = [
        claim(:source_b, :identity, %{ref: "B", codes: [{:cnk, "0222"}, {:gtin, "5001"}]}, @d1, @d1),
        claim(:source_a, :identity, %{ref: "A", codes: [{:cnk, "0111"}, {:gtin, "5001"}]}, @d1, @d1)
      ]

      unresolved = Priority.new(%{}, [])

      decisions =
        for ordered <- [claims, Enum.reverse(claims)] do
          {log, ledger} = resolve(ordered)
          {log, _ledger} = steward_merge(log, ledger)
          key = Api.resolve_key(log, {:gtin, "5001"})
          PublicId.canonical(:cnk, key, log, unresolved)
        end

      expected = %{
        canonical: nil,
        aliases: [{:cnk, "0111"}, {:cnk, "0222"}],
        status: :needs_review,
        candidates: [
          {:source_a, {:cnk, "0111"}},
          {:source_b, {:cnk, "0222"}}
        ]
      }

      assert decisions == [expected, expected]
    end

    test "no identity-grade collision in the normal case" do
      {log, _} =
        resolve([claim(:manufacturer, :identity, %{ref: "A", codes: [{:cnk, "0111"}]}, @d1, @d1)])

      assert PublicId.collisions(:cnk, log) == []
    end

    test "the guard catches a CNK that wrongly ends up on two keys" do
      claims = [
        claim(:manufacturer, :identity, %{ref: "A", codes: [{:cnk, "9"}, {:gtin, "A1"}]}, @d1, @d1),
        claim(:supplier, :identity, %{ref: "B", codes: [{:cnk, "9"}, {:gtin, "B1"}]}, @d1, @d1)
      ]

      {c, o} = stamp(claims, 1)
      res1 = IdentityLedger.decide(IdentityLedger.new(), {:reconcile, clusters(c), @d1})
      {res1, _} = stamp(res1, o)
      ledger1 = fold(res1, IdentityLedger.new())
      assert PublicId.collisions(:cnk, c ++ res1) == [], "while merged, the CNK owns one key"

      # marking an identity-grade code shared is forbidden — do it to prove the guard fires
      shared = Stewardship.shared_codes(Stewardship.mark_shared({:cnk, "9"}, :rogue, @d2))

      res2 =
        IdentityLedger.decide(
          ledger1,
          {:reconcile, Cluster.variants(Substrate.current(c), shared), shared, @d2}
        )

      assert [%{code: {:cnk, "9"}, keys: keys}] = PublicId.collisions(:cnk, c ++ res1 ++ res2)
      assert length(keys) == 2
    end
  end

  describe "steward-initiated split (Stewardship.split)" do
    @d3 ~D[2026-03-01]

    test "undoes a wrong merge: carved codes get a fresh key; attributes and media re-home" do
      {log, ledger} =
        resolve([
          claim(:manufacturer, :identity, %{ref: "A", codes: [{:gtin, "0111"}]}, @d1, @d1),
          claim(:manufacturer, :identity, %{ref: "B", codes: [{:gtin, "0222"}]}, @d1, @d1),
          claim(:manufacturer, :attribute, %{code: {:gtin, "0111"}, field: :weight_g, value: 250}, @d1, @d1),
          claim(:manufacturer, :attribute, %{code: {:gtin, "0222"}, field: :weight_g, value: 480}, @d1, @d1),
          claim(
            :manufacturer,
            :media,
            %{asset: {:dam, "IMG-B"}, target: {:gtin, "0222"}, role: :primary, uri: "cdn://b"},
            @d1,
            @d1
          )
        ])

      # the steward (wrongly) approves merging the two established keys
      {merge, o} =
        ledger.members
        |> Stewardship.approve_merge(["SK_1", "SK_2"], :alice, @d2)
        |> stamp(length(log) + 1)

      ledger2 = fold(merge, ledger)
      log2 = log ++ merge
      assert [%{variants: [fused]}] = History.now(log2, @priority)
      assert {:gtin, "0111"} in fused.codes and {:gtin, "0222"} in fused.codes

      # the steward splits B's code back out
      {split, _} = ledger2 |> Stewardship.split("SK_1", [[{:gtin, "0222"}]], :alice, @d3) |> stamp(o)
      ledger3 = fold(split, ledger2)
      log3 = log2 ++ split

      assert ledger3.members == %{
               "SK_1" => MapSet.new([{:gtin, "0111"}]),
               "SK_3" => MapSet.new([{:gtin, "0222"}])
             }

      # nothing re-imported: the same claims project to the right keys again
      golden = History.now(log3, @priority)
      a = find_variant(golden, {:gtin, "0111"})
      b = find_variant(golden, {:gtin, "0222"})
      assert {a.key, b.key} == {"SK_1", "SK_3"}
      assert attr(a, :weight_g).value == 250
      assert attr(b, :weight_g).value == 480
      assert [%{asset: {:dam, "IMG-B"}}] = b.media
      assert a.media == []

      # the split and the steward who made it survive in both keys' lineage
      assert Enum.any?(History.lineage(log3, "SK_3"), &match?(%Events.IdentitySplit{}, &1))

      assert Enum.any?(
               History.lineage(log3, "SK_1"),
               &match?(%Events.ConflictResolved{subject: {:split, "SK_1"}, by: :alice}, &1)
             )
    end

    test "carve-outs are canonicalized and clipped to codes the key owns" do
      {log, ledger} =
        resolve([
          claim(
            :manufacturer,
            :identity,
            %{ref: "A", codes: [{:ean, "5012345678900"}, {:gtin, "0111"}]},
            @d1,
            @d1
          )
        ])

      # the steward references the EAN form; a stray code the key never owned is ignored
      {split, _} =
        ledger
        |> Stewardship.split("SK_1", [[{:ean, "5012345678900"}, {:gtin, "9999"}]], :alice, @d2)
        |> stamp(length(log) + 1)

      ledger2 = fold(split, ledger)

      assert ledger2.members == %{
               "SK_1" => MapSet.new([{:gtin, "0111"}]),
               "SK_2" => MapSet.new([{:gtin, "05012345678900"}])
             }
    end
  end
end
