# The thin steward CLI (gr-bb7): mix tasks over Api.Steward — the same queue and the same
# decisions (four-eyes included), from the terminal. The tasks are convenience wrappers, so the
# tests stay correspondingly thin: argv parsing, and one end-to-end pass against the store.
defmodule Api.StewardCliTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  setup do
    {:ok, :ok} = Api.Store.reset!()
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      System.delete_env("STEWARD_API_TOKEN")
    end)

    :ok
  end

  defp product!(method, path, body) do
    conn(method, path, JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer test-product-token")
    |> then(&Api.Router.call(&1, Api.Router.init([])))
  end

  # two established keys first, then the bridging listing — so the merge is PROPOSED, not minted
  defp seed_bridged do
    product!(:post, "/v1/claims", %{
      claims: [
        %{
          kind: "identity",
          source: "acme",
          ref: "A",
          codes: ["cnk:1000001", "gtin:05012345678900"]
        },
        %{
          kind: "identity",
          source: "bolt",
          ref: "B",
          codes: ["cnk:1000002", "gtin:08712345678906"]
        }
      ]
    })

    product!(:post, "/v1/claims", %{
      claims: [
        %{
          kind: "identity",
          source: "mkt",
          ref: "K",
          codes: ["gtin:05012345678900", "gtin:08712345678906"]
        }
      ]
    })

    Api.Store.state().ledger.members |> Map.keys() |> Enum.sort()
  end

  defp shell_output do
    {:messages, messages} = Process.info(self(), :messages)
    for {:mix_shell, :info, [line]} <- messages, do: line
  end

  describe "argv parsing (Mix.Tasks.Steward.Decide.parse/1)" do
    test "approve_merge with keys and reason" do
      assert {:ok,
              %{
                "kind" => "approve_merge",
                "keys" => ["SK_1", "SK_2"],
                "reason" => "same product"
              }} =
               Mix.Tasks.Steward.Decide.parse([
                 "approve_merge",
                 "--keys",
                 "SK_1+SK_2",
                 "--reason",
                 "same product"
               ])
    end

    test "resolve_attribute and split shapes" do
      assert {:ok,
              %{
                "kind" => "resolve_attribute",
                "key" => "SK_1",
                "field" => "color",
                "value" => "ivory"
              }} =
               Mix.Tasks.Steward.Decide.parse(
                 ~w(resolve_attribute --key SK_1 --field color --value ivory)
               )

      assert {:ok, %{"kind" => "split", "codes" => ["gtin:1", "cnk:2"]}} =
               Mix.Tasks.Steward.Decide.parse([
                 "split",
                 "--key",
                 "SK_1",
                 "--codes",
                 "gtin:1 cnk:2"
               ])
    end

    test "garbage argv is a usage error, not a decision" do
      assert {:error, "usage:" <> _} = Mix.Tasks.Steward.Decide.parse([])
      assert {:error, "usage:" <> _} = Mix.Tasks.Steward.Decide.parse(["split", "--bogus", "x"])
    end
  end

  describe "end to end against the store" do
    test "steward.queue lists the pending merge; steward.decide walks four-eyes" do
      [k1, k2] = seed_bridged()

      Mix.Tasks.Steward.Queue.run([])
      output = Enum.join(shell_output(), "\n")
      assert output =~ "merge  #{k1} + #{k2}"
      assert output =~ "needs two distinct stewards"

      # first decide endorses
      System.put_env("STEWARD_API_TOKEN", "test-steward-token")

      Mix.Tasks.Steward.Decide.run(~w(approve_merge --keys #{k1}+#{k2} --reason verified))

      assert map_size(Api.Store.state().ledger.members) == 2

      assert %{by: "sam", reason: "verified"} =
               Api.Store.state().proposals[[k1, k2]] |> Map.take([:by, :reason])

      # the same steward again is refused — the task surfaces the engine's verdict
      assert_raise Mix.Error, fn ->
        Mix.Tasks.Steward.Decide.run(~w(approve_merge --keys #{k1}+#{k2}))
      end

      # a second steward fuses
      System.put_env("STEWARD_API_TOKEN", "test-alex-token")
      Mix.Tasks.Steward.Decide.run(~w(approve_merge --keys #{k1}+#{k2}))
      assert map_size(Api.Store.state().ledger.members) == 1
    end
  end
end
