defmodule Api.ContractTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  @root Path.expand("../..", __DIR__)
  @examples Path.join(@root, "contract/api_examples.json")
  @openapi Path.join(@root, "api/openapi.yaml")

  setup do
    {:ok, :ok} = Api.Store.reset!()
    :ok
  end

  defp request(method, path, body \\ nil, token \\ "test-product-token") do
    conn(method, path, body && JSON.encode!(body))
    |> then(&if(body, do: put_req_header(&1, "content-type", "application/json"), else: &1))
    |> put_req_header("authorization", "Bearer #{token}")
    |> then(&Api.Router.call(&1, Api.Router.init([])))
  end

  defp decoded(conn), do: JSON.decode!(conn.resp_body)

  test "OpenAPI declares every implemented pilot route and external JSON Schema" do
    contract = File.read!(@openapi)

    for path <- [
          "/health",
          "/ready",
          "/v1/backfill/envelopes",
          "/v1/claims",
          "/v1/dry-run",
          "/v1/cutover",
          "/v1/source-records/{source}/{ref}/revisions/{revision}",
          "/v1/source-records/{source}/{ref}",
          "/v1/products/{legacy_id}",
          "/v1/products/by-code/{scheme}/{code}",
          "/v1/identities/{key}",
          "/v1/metadata",
          "/v1/changes",
          "/steward/v1/queue",
          "/steward/v1/decisions",
          "/steward"
        ] do
      assert contract =~ "  #{path}:"
    end

    assert contract =~ "../contract/source_record.schema.json"
    assert contract =~ "../contract/steward_decision.schema.json"
    assert contract =~ "known_at"
    assert contract =~ "effective_at"
  end

  test "all contract JSON documents parse and expose the implemented temporal/case fields" do
    claims = @root |> Path.join("contract/claims.schema.json") |> File.read!() |> JSON.decode!()

    source =
      @root |> Path.join("contract/source_record.schema.json") |> File.read!() |> JSON.decode!()

    decision =
      @root
      |> Path.join("contract/steward_decision.schema.json")
      |> File.read!()
      |> JSON.decode!()

    registry =
      @root |> Path.join("contract/scheme_registry.schema.json") |> File.read!() |> JSON.decode!()

    examples = @examples |> File.read!() |> JSON.decode!()

    assert claims["$defs"]["identityClaim"]["properties"]["valid_to"]

    assert source["properties"]["operation"]["enum"] == [
             "replace",
             "patch",
             "withdraw",
             "reactivate"
           ]

    assert Map.has_key?(decision["properties"], "case_id")
    refute Map.has_key?(decision["properties"], "by")
    assert registry["properties"]["schemes"]

    assert Map.keys(examples["examples"]) |> Enum.sort() ==
             ["clean_merge", "contradiction", "late_correction"]
  end

  test "the clean-merge example executes as documented" do
    example = example("clean_merge")
    conn = execute(example["request"])

    assert conn.status == example["expect"]["status"]
    assert map_size(Api.Store.state().ledger.members) == example["expect"]["identity_count"]
  end

  test "the contradiction example executes and returns an unresolved attribute" do
    example = example("contradiction")
    assert execute(example["request"]).status == example["expect"]["status"]

    [legacy_id] = Api.Store.state().assigned |> Map.values()
    product = request(:get, "/v1/products/#{legacy_id}") |> decoded()
    color = Enum.find(product["attributes"], &(&1["field"] == "color"))

    assert color["status"] == example["expect"]["attribute_status"]
    assert color["value"] == nil
    assert color["winner"] == nil
  end

  test "the late-correction example executes under independent effective clocks" do
    example = example("late_correction")

    responses = Enum.map(example["requests"], &execute/1)
    assert Enum.all?(responses, &(&1.status == example["expect"]["status"]))

    legacy_id = responses |> hd() |> decoded() |> Map.fetch!("legacy_id")

    before =
      request(:get, "/v1/products/#{legacy_id}?effective_at=2026-01-15")
      |> decoded()
      |> attribute("name")

    after_change =
      request(:get, "/v1/products/#{legacy_id}?effective_at=2026-02-15")
      |> decoded()
      |> attribute("name")

    assert before["value"] == example["expect"]["before_effective"]
    assert after_change["value"] == example["expect"]["after_effective"]
  end

  test "identity and metadata responses match their declared contract" do
    execute(example("clean_merge")["request"])
    [key] = Api.Store.state().ledger.members |> Map.keys()

    identity = request(:get, "/v1/identities/#{key}") |> decoded()
    assert identity["key"] == key
    assert identity["current_key"] == key
    assert identity["status"] == "active"
    assert identity["lane"] == "product"

    metadata = request(:get, "/v1/metadata") |> decoded()
    assert metadata["schema_version"] == "1"
    assert metadata["review_policy"]["distinct_authenticated_principals"] == true
    assert Enum.any?(metadata["schemes"], &(&1["canonical_name"] == "cnk"))
    assert Enum.any?(metadata["relations"], &(&1["name"] == "describes"))
  end

  test "stable clock and identity errors expose an error string and code where applicable" do
    bad_clock = request(:get, "/v1/products/1?known_at=yesterday")
    assert bad_clock.status == 422
    assert is_binary(decoded(bad_clock)["error"])

    missing = request(:get, "/v1/identities/SK_999")
    assert missing.status == 404

    assert decoded(missing) == %{
             "error" => "unknown identity SK_999",
             "code" => "identity_not_found"
           }
  end

  defp example(name),
    do: @examples |> File.read!() |> JSON.decode!() |> get_in(["examples", name])

  defp execute(%{"method" => method, "path" => path, "body" => body}),
    do: request(method |> String.downcase() |> String.to_existing_atom(), path, body)

  defp attribute(product, field), do: Enum.find(product["attributes"], &(&1["field"] == field))
end
