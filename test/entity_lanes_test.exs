# entity_lanes_test.exs — typed entity lanes, edge claims, and derived visibility (gr-pie).
#
# The design (docs/plans/2026-06-12-entity-lanes-and-edges-design.md): every entity is its own
# golden record in a typed lane; relationships are code↔code edge claims; the product page is a
# derived read-time traversal — "product C newly contains substance A ⇒ A's descriptions appear
# on C" is a fold recomputing, never a copy.

alias GoldenRecord.{Lanes, Uuid, Substrate, Priority, IdentityLedger, Stewardship, Catalog}

defmodule EntityLanesTest do
  use ExUnit.Case, async: true
  import Substrate, only: [claim: 5]

  @d1 ~D[2026-01-10]
  @d2 ~D[2026-02-01]

  @priority Priority.new(%{}, [[:vidal], [:supplier], [:manufacturer]])
  @no_overrides %{attr: %{}, product: %{}}

  # ── helpers ──
  defp stamp(events, start),
    do: {Enum.map(Enum.with_index(events, start), fn {e, i} -> %{e | order: i} end), start + length(events)}

  defp fold(events), do: Enum.reduce(events, IdentityLedger.new(), &IdentityLedger.evolve(&2, &1))

  # full per-lane pass: claims → live → Lanes.reconcile → members → Catalog.project
  defp build(claims, at \\ @d1) do
    {stamped, o} = stamp(claims, 1)
    live = Substrate.current(stamped)
    {events, ledgers} = Lanes.reconcile(live, MapSet.new(), Lanes.new_ledgers(), at)
    {events, _} = stamp(events, o)
    %{live: live, events: events, ledgers: ledgers, members: fold(events).members}
  end

  defp project(claims, at \\ @d1) do
    %{live: live, members: members} = build(claims, at)
    Catalog.project(members, live, @priority, @no_overrides)
  end

  defp find_variant(golden, code),
    do: golden |> Enum.flat_map(& &1.variants) |> Enum.find(&(code in &1.codes))

  defp attr_value(record, field) do
    {_, decision} = List.keyfind(record.attributes, field, 0)
    decision.value
  end

  # the user's scenario: products A and B contain substance PARA; description D1 describes PARA
  defp scenario do
    [
      claim(:supplier, :identity, %{ref: "A", codes: [{:cnk, "0111"}]}, @d1, @d1),
      claim(:supplier, :identity, %{ref: "B", codes: [{:cnk, "0222"}]}, @d1, @d1),
      claim(:vidal, :identity, %{ref: "PARA", codes: [{:substance_id, "PARA"}]}, @d1, @d1),
      claim(:vidal, :identity, %{ref: "D1", codes: [{:text_id, "D1"}]}, @d1, @d1),
      claim(:vidal, :attribute, %{code: {:text_id, "D1"}, field: "text", value: "Relieves pain."}, @d1, @d1),
      claim(
        :supplier,
        :edge,
        %{from: {:cnk, "0111"}, relation: :contains, to: {:substance_id, "PARA"}},
        @d1,
        @d1
      ),
      claim(
        :supplier,
        :edge,
        %{from: {:cnk, "0222"}, relation: :contains, to: {:substance_id, "PARA"}},
        @d1,
        @d1
      ),
      claim(
        :vidal,
        :edge,
        %{from: {:text_id, "D1"}, relation: :describes, to: {:substance_id, "PARA"}},
        @d1,
        @d1
      )
    ]
  end

  describe "typed entity lanes (gr-2a8)" do
    test "each lane folds its own ledger under its own key prefix" do
      %{members: members} = build(scenario())

      assert Map.keys(members) |> Enum.sort() == ["DSC_1", "SK_1", "SK_2", "SUB_1"]
      assert members["SUB_1"] == MapSet.new([{:substance_id, "PARA"}])
      assert members["DSC_1"] == MapSet.new([{:text_id, "D1"}])
    end

    test "lane routing: scheme decides; uuid is neutral and falls back to the explicit entity" do
      assert Lanes.of_claim(claim(:s, :identity, %{ref: "x", codes: [{:cnk, "1"}]}, @d1, @d1)) ==
               {:ok, :product}

      assert Lanes.of_claim(claim(:s, :identity, %{ref: "x", codes: [{:cas, "50-78-2"}]}, @d1, @d1)) ==
               {:ok, :substance}

      uuid = Uuid.mint()

      assert Lanes.of_claim(claim(:s, :identity, %{ref: "x", codes: [uuid], entity: :description}, @d1, @d1)) ==
               {:ok, :description}
    end

    test "an identity claim mixing two lanes belongs to no lane (contract violation)" do
      mixed = claim(:s, :identity, %{ref: "x", codes: [{:cnk, "1"}, {:cas, "50-78-2"}]}, @d1, @d1)
      assert Lanes.of_claim(mixed) == {:error, {:mixed_lanes, [:product, :substance]}}
      assert Lanes.identity_claims([mixed], :product) == []
      assert Lanes.identity_claims([mixed], :substance) == []
    end

    test "minted uuids are v4-shaped and unique" do
      {scheme, value} = Uuid.mint()
      assert scheme == :uuid
      assert value =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      assert Uuid.mint() != Uuid.mint()
    end

    test "lane_records: a non-product lane projects standalone, first-class records" do
      %{live: live, members: members} = build(scenario())
      lanes = Lanes.partition_members(members)

      assert [record] = Catalog.lane_records(lanes.description, live, @priority)
      assert record.key == "DSC_1"
      assert record.codes == [{:text_id, "D1"}]
      assert attr_value(record, "text") == "Relieves pain."
    end
  end

  describe "derived visibility (gr-sw0) — the A/B/C scenario" do
    test "a description tagged to substance A shows on every product containing A, with provenance" do
      golden = project(scenario())

      for cnk <- ["0111", "0222"] do
        variant = find_variant(golden, {:cnk, cnk})
        assert [d] = variant.descriptions
        assert d.key == "DSC_1"
        assert d.via == {:substance, "SUB_1"}
        assert d.asserted_by == [:vidal]
        assert attr_value(d, "text") == "Relieves pain."
      end
    end

    test "product C newly claiming substance A pulls the description in — derived, never copied" do
      late =
        scenario() ++
          [
            claim(:supplier, :identity, %{ref: "C", codes: [{:cnk, "0333"}]}, @d2, @d2),
            claim(
              :supplier,
              :edge,
              %{from: {:cnk, "0333"}, relation: :contains, to: {:substance_id, "PARA"}},
              @d2,
              @d2
            )
          ]

      variant = find_variant(project(late), {:cnk, "0333"})
      assert [%{key: "DSC_1", via: {:substance, "SUB_1"}}] = variant.descriptions
    end

    test "a directly-tagged description shows with via: :direct" do
      direct =
        scenario() ++
          [
            claim(:vidal, :identity, %{ref: "D2", codes: [{:text_id, "D2"}]}, @d1, @d1),
            claim(
              :vidal,
              :edge,
              %{from: {:text_id, "D2"}, relation: :describes, to: {:cnk, "0111"}},
              @d1,
              @d1
            )
          ]

      variant = find_variant(project(direct), {:cnk, "0111"})
      assert [%{key: "DSC_2", via: :direct} | _] = variant.descriptions
      assert Enum.map(variant.descriptions, & &1.key) |> Enum.sort() == ["DSC_1", "DSC_2"]
    end

    test "relation-scoped: a description tagged to a substance the product does NOT contain stays off the page" do
      unrelated =
        scenario() ++
          [
            claim(:vidal, :identity, %{ref: "WATER", codes: [{:substance_id, "WATER"}]}, @d1, @d1),
            claim(:vidal, :identity, %{ref: "D3", codes: [{:text_id, "D3"}]}, @d1, @d1),
            claim(
              :vidal,
              :edge,
              %{from: {:text_id, "D3"}, relation: :describes, to: {:substance_id, "WATER"}},
              @d1,
              @d1
            )
          ]

      variant = find_variant(project(unrelated), {:cnk, "0111"})
      assert Enum.map(variant.descriptions, & &1.key) == ["DSC_1"]
    end

    test "the variant lists its substances, resolved to lane keys with sources" do
      variant = find_variant(project(scenario()), {:cnk, "0111"})
      assert [%{key: "SUB_1", codes: [{:substance_id, "PARA"}], sources: [:supplier]}] = variant.substances
    end

    test "a substance merge converges visibility at read time — zero writes to the description" do
      split_world = [
        claim(:supplier, :identity, %{ref: "A", codes: [{:cnk, "0111"}]}, @d1, @d1),
        # two substance records that turn out to be the same thing
        claim(:vidal, :identity, %{ref: "S1", codes: [{:substance_id, "ASA"}]}, @d1, @d1),
        claim(:manufacturer, :identity, %{ref: "S2", codes: [{:cas, "50-78-2"}]}, @d1, @d1),
        claim(:vidal, :identity, %{ref: "D1", codes: [{:text_id, "D1"}]}, @d1, @d1),
        # the product contains one spelling; the description describes the OTHER
        claim(
          :supplier,
          :edge,
          %{from: {:cnk, "0111"}, relation: :contains, to: {:substance_id, "ASA"}},
          @d1,
          @d1
        ),
        claim(:vidal, :edge, %{from: {:text_id, "D1"}, relation: :describes, to: {:cas, "50-78-2"}}, @d1, @d1)
      ]

      %{live: live, events: events, ledgers: ledgers} = build(split_world)

      # before the merge: two substance records, the description does not reach the product
      refute match?(
               [_ | _],
               find_variant(
                 Catalog.project(fold(events).members, live, @priority, @no_overrides),
                 {:cnk, "0111"}
               ).descriptions
             )

      merge = Stewardship.approve_merge(ledgers.substance.members, ["SUB_1", "SUB_2"], "alice", @d2)
      members = fold(events ++ merge).members

      variant = find_variant(Catalog.project(members, live, @priority, @no_overrides), {:cnk, "0111"})
      assert [%{key: "DSC_1", via: {:substance, "SUB_1"}}] = variant.descriptions
    end
  end

  describe "steward suppress (gr-745)" do
    test "four-eyes: the proposing steward cannot also approve" do
      assert {:proposed, [proposal]} =
               Stewardship.endorse_suppress({:text_id, "D1"}, {:cnk, "0111"}, nil, "alice", @d2)

      assert Stewardship.endorse_suppress({:text_id, "D1"}, {:cnk, "0111"}, proposal, "alice", @d2) ==
               {:error, :four_eyes}
    end

    test "an approved suppress hides the pairing on THAT product only; the substance tag survives" do
      {:proposed, [proposal]} =
        Stewardship.endorse_suppress({:text_id, "D1"}, {:cnk, "0111"}, nil, "alice", @d2)

      {:ok, [suppress_edge, _resolved]} =
        Stewardship.endorse_suppress({:text_id, "D1"}, {:cnk, "0111"}, proposal, "bob", @d2)

      golden = project(scenario() ++ [suppress_edge], @d2)

      assert find_variant(golden, {:cnk, "0111"}).descriptions == []
      # The suppress hides only the description↔product pairing; the substance tag is untouched.
      assert [%{key: "SUB_1"}] = find_variant(golden, {:cnk, "0111"}).substances
      assert [%{key: "DSC_1"}] = find_variant(golden, {:cnk, "0222"}).descriptions
    end

    test "pending_suppress replays the open proposal from the log, and clears once decided" do
      {:proposed, [proposal]} =
        Stewardship.endorse_suppress({:text_id, "D1"}, {:cnk, "0111"}, nil, "alice", @d2)

      assert Stewardship.pending_suppress([proposal], {:text_id, "D1"}, {:cnk, "0111"}) == proposal

      {:ok, decided} =
        Stewardship.endorse_suppress({:text_id, "D1"}, {:cnk, "0111"}, proposal, "bob", @d2)

      assert Stewardship.pending_suppress([proposal | decided], {:text_id, "D1"}, {:cnk, "0111"}) == nil
    end
  end

  describe "edge claims (gr-xde)" do
    test "member_of is lowered to an :edge with relation :member_of — categories still resolve" do
      lowered = claim(:s, :member_of, %{member_code: {:cnk, "0111"}, collection: {:atc, "A10"}}, @d1, @d1)
      assert lowered.kind == :edge
      assert lowered.data == %{from: {:cnk, "0111"}, relation: :member_of, to: {:atc, "A10"}}

      golden =
        project([
          claim(:supplier, :identity, %{ref: "A", codes: [{:cnk, "0111"}]}, @d1, @d1),
          lowered
        ])

      assert find_variant(golden, {:cnk, "0111"}).categories == [{:atc, "A10"}]
    end

    test "resubmitting the same edge is idempotent (one slot, latest wins)" do
      e1 = claim(:s, :edge, %{from: {:cnk, "0111"}, relation: :contains, to: {:cas, "50-78-2"}}, @d1, @d1)
      e2 = claim(:s, :edge, %{from: {:cnk, "0111"}, relation: :contains, to: {:cas, "50-78-2"}}, @d2, @d2)
      {stamped, _} = stamp([e1, e2], 1)

      assert [live] = Substrate.current(stamped)
      assert live.valid_from == @d2
    end

    test "edge endpoints canonicalize, so an EAN-13 edge matches a GTIN-14 cluster" do
      e = claim(:s, :edge, %{from: {:ean, "5012345678900"}, relation: :contains, to: {:cas, "1"}}, @d1, @d1)
      assert e.data.from == {:gtin, "05012345678900"}
    end
  end

  describe "contract (gr-dig/gr-7cu): validator + canonical claims" do
    test "a well-formed edge claim validates and translates" do
      batch = [
        %{
          "kind" => "edge",
          "source" => "vidal",
          "from" => "text_id:D1",
          "relation" => "describes",
          "to" => "substance_id:PARA",
          "valid_from" => "2026-01-10"
        }
      ]

      assert {:ok, []} = ClaimsValidator.validate(batch)

      assert {:ok, [c]} = CanonicalClaims.to_engine(batch, recorded_at: @d1)
      assert c.kind == :edge
      assert c.data == %{from: {:text_id, "D1"}, relation: :describes, to: {:substance_id, "PARA"}}
    end

    test "an unknown relation rejects" do
      batch = [
        %{"kind" => "edge", "source" => "s", "from" => "cnk:1", "relation" => "likes", "to" => "cas:2"}
      ]

      assert {:error, [%{field: "relation"}]} = ClaimsValidator.validate(batch)
    end

    test "an edge violating the relation's lane signature rejects" do
      # contains: product → substance, but both endpoints here are product codes
      batch = [
        %{"kind" => "edge", "source" => "s", "from" => "cnk:1", "relation" => "contains", "to" => "cnk:2"}
      ]

      assert {:error, [%{field: "relation", error: error}]} = ClaimsValidator.validate(batch)
      assert error =~ "lane signature"
    end

    test "identity codes mixing two lanes reject" do
      batch = [%{"kind" => "identity", "source" => "s", "ref" => "x", "codes" => ["cnk:1", "cas:2"]}]
      assert {:error, [%{field: "codes", error: error}]} = ClaimsValidator.validate(batch)
      assert error =~ "mix entity lanes"
    end

    test "entity must be a known lane name; a valid one routes an all-uuid claim" do
      bad = [
        %{"kind" => "identity", "source" => "s", "ref" => "x", "codes" => ["uuid:0000"], "entity" => "blob"}
      ]

      assert {:error, [%{field: "entity"}]} = ClaimsValidator.validate(bad)

      good = [
        %{
          "kind" => "identity",
          "source" => "s",
          "ref" => "x",
          "codes" => ["uuid:0000"],
          "entity" => "description"
        }
      ]

      assert {:ok, []} = ClaimsValidator.validate(good)

      assert [c] = CanonicalClaims.to_engine!(good, recorded_at: @d1)
      assert Lanes.of_claim(c) == {:ok, :description}
    end
  end
end
