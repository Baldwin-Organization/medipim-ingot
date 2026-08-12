defmodule SchemeRegistryTest do
  use ExUnit.Case, async: true

  @document %{
    "schema_version" => "1",
    "schemes" => [
      %{
        "name" => "sku",
        "class" => "identity",
        "entity_type" => "product",
        "bridge_grade" => "national",
        "normalizer" => %{"kind" => "trim"},
        "aliases" => ["stock_code"]
      },
      %{
        "name" => "substance_key",
        "class" => "identity",
        "entity_type" => "substance",
        "bridge_grade" => "national",
        "normalizer" => %{"kind" => "trim"}
      }
    ],
    "relations" => [
      %{"name" => "made_of", "from" => ["product"], "to" => ["substance"]}
    ]
  }

  test "loads scheme and relation rules as data without creating atoms from their names" do
    assert {:ok, registry} = SchemeRegistry.from_map(@document)

    assert SchemeRegistry.canonical_name(registry, "stock_code") == "sku"
    assert SchemeRegistry.class(registry, "stock_code") == :identity
    assert SchemeRegistry.bridge_grade(registry, "sku") == :national
    assert SchemeRegistry.lane(registry, "substance_key") == :substance

    assert {:ok, %{name: "made_of", from: [:product], to: [:substance]}} =
             SchemeRegistry.relation(registry, "made_of")
  end

  test "Lanes and Relations use runtime declarations before their built-in fallback" do
    registry = SchemeRegistry.from_map!(@document)

    assert Lanes.lane_of_scheme("substance_key", registry) == :substance
    assert Lanes.lane_of_scheme("unknown", registry) == :product

    assert Relations.parse("made_of", registry) == {:ok, "made_of"}

    assert Relations.valid_signature?(
             "made_of",
             {"sku", "ABC"},
             {"substance_key", "PARA"},
             registry
           )

    refute Relations.valid_signature?(
             "made_of",
             {"substance_key", "PARA"},
             {"sku", "ABC"},
             registry
           )
  end

  test "canonical claims validate and reconcile with deployment-defined schemes and relations" do
    registry = SchemeRegistry.from_map!(@document)

    batch = [
      %{"kind" => "identity", "source" => "catalog", "ref" => "p1", "codes" => ["stock_code:ABC"]},
      %{
        "kind" => "identity",
        "source" => "catalog",
        "ref" => "s1",
        "codes" => ["substance_key:PARA"]
      },
      %{
        "kind" => "edge",
        "source" => "catalog",
        "from" => "sku:ABC",
        "relation" => "made_of",
        "to" => "substance_key:PARA"
      }
    ]

    opts = [recorded_at: ~D[2026-07-10], scheme_registry: registry]
    assert {:ok, []} = ClaimsValidator.validate(batch, opts)
    assert {:ok, claims} = CanonicalClaims.to_engine(batch, opts)

    [product, substance, edge] = claims
    assert product.data.codes == [{"sku", "ABC"}]
    assert substance.data.codes == [{"substance_key", "PARA"}]
    assert edge.data.relation == "made_of"

    live =
      claims
      |> Enum.with_index(1)
      |> Enum.map(fn {claim, order} -> %{claim | order: order} end)
      |> Substrate.current()

    {events, ledgers} =
      Lanes.reconcile(live, MapSet.new(), Lanes.new_ledgers(), ~D[2026-07-10], registry)

    assert Enum.any?(events, &match?(%Events.IdentityMinted{key: "SK_1"}, &1))
    assert Enum.any?(events, &match?(%Events.IdentityMinted{key: "SUB_1"}, &1))
    assert Map.has_key?(ledgers.product.members, "SK_1")
    assert Map.has_key?(ledgers.substance.members, "SUB_1")
  end

  test "rejects ambiguous aliases and invalid relation lanes" do
    ambiguous =
      put_in(
        @document["schemes"],
        @document["schemes"] ++
          [%{"name" => "other", "class" => "identity", "aliases" => ["stock_code"]}]
      )

    assert {:error, errors} = SchemeRegistry.from_map(ambiguous)
    assert Enum.any?(errors, &String.contains?(&1, ~s(alias "stock_code" is declared more than once)))

    invalid = put_in(@document["relations"], [%{"name" => "made_of", "from" => ["planet"], "to" => nil}])

    assert {:error, errors} = SchemeRegistry.from_map(invalid)
    assert Enum.any?(errors, &String.contains?(&1, ~s(unknown lane "planet")))
  end
end
