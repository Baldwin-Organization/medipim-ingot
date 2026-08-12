# test/contract/canonical_claims_test.exs — the canonical-claims seam (bead gr-3jd).
#
# CanonicalClaims is stage (b) of the productized ingest: wire-shaped claim maps
# (docs/CLAIMS_CONTRACT.md) → engine claims. The medipim reference adapter (ClaimMapping) is
# stage (a). These tests pin the seam itself; the engine-claim INVARIANT (build/1 output
# unchanged by the split) stays pinned by the existing claim_mapping / walkthrough / fixture /
# temporal suites, which are deliberately untouched.

defmodule CanonicalClaimsTest do
  use ExUnit.Case, async: true

  describe "to_engine/2 — the validated live-wire seam" do
    test "a valid live batch translates: ISO valid_from, server-side recorded_at" do
      batch = [
        %{
          "kind" => "identity",
          "source" => "medipim",
          "ref" => "P-1",
          "codes" => ["cnk:1000001", "ean:5012345678900"],
          "valid_from" => "2024-03-01"
        },
        %{
          "kind" => "attribute",
          "source" => "medipim",
          "code" => "cnk:1000001",
          "field" => "name",
          "value" => "Sunscreen"
        }
      ]

      today = ~D[2026-06-11]
      assert {:ok, [identity, attribute]} = CanonicalClaims.to_engine(batch, recorded_at: today)

      # codes parse + canonicalize (EAN-13 → GTIN-14); valid_from honored, recorded_at server-side
      assert identity.data == %{ref: "P-1", codes: [{:cnk, "1000001"}, {:gtin, "05012345678900"}]}
      assert identity.valid_from == ~D[2024-03-01]
      assert identity.recorded_at == today

      # no valid_from on the claim → defaults to recorded_at
      assert attribute.data == %{code: {:cnk, "1000001"}, field: "name", value: "Sunscreen"}
      assert attribute.valid_from == today
    end

    test "an invalid batch rejects whole with the validator's per-index findings" do
      assert {:error, [%{index: 0, field: "codes"}]} =
               CanonicalClaims.to_engine(
                 [%{"kind" => "identity", "source" => "s", "ref" => "P-1", "codes" => "not-a-list"}],
                 recorded_at: ~D[2026-06-11]
               )
    end

    test "an identity claim with empty codes passes validation (retraction)" do
      assert {:ok, [claim]} =
               CanonicalClaims.to_engine(
                 [%{"kind" => "identity", "source" => "s", "ref" => "P-1", "codes" => []}],
                 recorded_at: ~D[2026-06-11]
               )

      assert claim.data.codes == []
    end
  end

  describe "to_engine!/2 — the trusted backfill seam" do
    test "carries the backfill flavor the live wire rejects: member_of + unix-second temporals" do
      batch = [
        %{
          "kind" => "member_of",
          "source" => "44",
          "code" => "cnk:3612173",
          "collection" => "brands",
          "member" => "211",
          "valid_from" => 1_535_726_805,
          "recorded_at" => 1_535_726_805
        }
      ]

      # member_of is the legacy spelling of an :edge (gr-xde): the wire shape is unchanged,
      # but the log holds the generalized edge — one relationship representation.
      assert [claim] = CanonicalClaims.to_engine!(batch)
      assert claim.kind == :edge
      assert claim.data == %{from: {:cnk, "3612173"}, relation: :member_of, to: {"brands", "211"}}
      assert claim.valid_from == 1_535_726_805
      assert claim.recorded_at == 1_535_726_805
    end
  end

  describe ~s(codes — "scheme:value" both directions) do
    test "parse_code/1 folds engine-native names to their atoms, splits on the FIRST colon" do
      assert CanonicalClaims.parse_code("cnk:1000001") == {:ok, {:cnk, "1000001"}}
      assert CanonicalClaims.parse_code("mpn:AB:12") == {:ok, {:mpn, "AB:12"}}
      assert {:error, _} = CanonicalClaims.parse_code("no-colon")
      assert {:error, _} = CanonicalClaims.parse_code(":empty-scheme")
    end

    test "code_string/1 is parse_code's inverse — engine atoms AND unknown string schemes" do
      for code <- [{:cnk, "1000001"}, {:gtin, "05012345678900"}, {"mysteryScheme", "XYZ"}] do
        assert CanonicalClaims.parse_code(CanonicalClaims.code_string(code)) == {:ok, code}
      end
    end
  end

  describe "the medipim reference adapter feeds the seam (ClaimMapping.canonical_claims/1)" do
    test "stage (a) emits wire-shaped maps; stage (b) rebuilds exactly what build/1 yields" do
      {:ok, env} =
        HistoryEnvelope.from_map(%{
          "schema_version" => "1",
          "legacy_entity" => 99,
          "events" => [
            %{
              "recorded_at" => 10,
              "source" => "A",
              "op" => "set",
              "kind" => "identity",
              "scheme" => "cnk",
              "code" => "1000001"
            },
            %{
              "recorded_at" => 20,
              "source" => "A",
              "op" => "set",
              "kind" => "attribute",
              "field" => "name",
              "locale" => "fr",
              "value" => "Crème"
            },
            %{
              "recorded_at" => 30,
              "source" => "A",
              "op" => "add",
              "kind" => "edge",
              "collection" => "brands",
              "value" => 211
            }
          ]
        })

      canonical = ClaimMapping.canonical_claims([env])

      assert canonical == [
               # An identity claim now covers a PERIOD of the listing's code set, so it carries
               # valid_to. One period here — the set never changed — so the interval is open.
               %{
                 "kind" => "identity",
                 "source" => "A",
                 "ref" => "99:A",
                 "codes" => ["cnk:1000001"],
                 "valid_from" => 10,
                 "valid_to" => nil,
                 "recorded_at" => 10
               },
               %{
                 "kind" => "grouping",
                 "source" => "A",
                 "code" => "cnk:1000001",
                 "product" => 99,
                 "valid_from" => 10,
                 "valid_to" => nil,
                 "recorded_at" => 10
               },
               %{
                 "kind" => "attribute",
                 "source" => "A",
                 "code" => "cnk:1000001",
                 "field" => "name:fr",
                 "value" => "Crème",
                 "valid_from" => 20,
                 "recorded_at" => 20
               },
               %{
                 "kind" => "member_of",
                 "source" => "A",
                 "code" => "cnk:1000001",
                 "collection" => "brands",
                 "member" => "211",
                 "valid_from" => 30,
                 "recorded_at" => 30
               }
             ]

      # the composed pipeline equals build/1 (modulo build's chronological order stamps)
      stamped = ClaimMapping.build([env]).claims
      assert Enum.map(stamped, &%{&1 | order: nil}) == CanonicalClaims.to_engine!(canonical)
    end
  end
end
