defmodule Mix.Tasks.Steward.Decide do
  @shortdoc "Submit a steward decision (approve_merge | reject_merge | resolve_attribute | split)"

  @moduledoc """
  A thin convenience wrapper over the authenticated steward surface. Set `STEWARD_API_TOKEN` to
  one steward's bearer token; the credential determines the actor. Four-eyes applies unchanged:
  the first `approve_merge` endorses and a different steward credential fuses.

      STEWARD_API_TOKEN=... mix steward.decide approve_merge --keys SK_1+SK_2 --reason "same product"
      STEWARD_API_TOKEN=... mix steward.decide reject_merge --keys SK_1+SK_2 --reason "bundle vs unit"
      STEWARD_API_TOKEN=... mix steward.decide resolve_attribute --key SK_1 --field color --value ivory
      STEWARD_API_TOKEN=... mix steward.decide split --key SK_1 --codes "gtin:0871... cnk:7654321"
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    case parse(argv) do
      {:ok, decision} ->
        Mix.Tasks.Steward.Queue.start_app!()
        principal = authenticate!()
        {status, body} = decision |> attach_case() |> Api.Steward.decide(principal)
        Mix.shell().info("#{status} #{JSON.encode!(body)}")
        if status != 200, do: Mix.raise("decision was not applied (#{status})")

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @doc "Parse argv into a steward decision map."
  def parse(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          keys: :string,
          key: :string,
          field: :string,
          value: :string,
          codes: :string,
          reason: :string
        ]
      )

    with [kind] <- args,
         [] <- invalid do
      {:ok,
       %{"kind" => kind}
       |> put_if("reason", opts[:reason])
       |> put_if("keys", opts[:keys] && String.split(opts[:keys], "+", trim: true))
       |> put_if("key", opts[:key])
       |> put_if("field", opts[:field])
       |> put_if("value", opts[:value])
       |> put_if("codes", opts[:codes] && String.split(opts[:codes], ~r/[\s,]+/, trim: true))}
    else
      _ ->
        {:error,
         "usage: mix steward.decide <kind> [--reason <text>] " <>
           "[--keys SK_1+SK_2 | --key SK_1 --field f --value v | --key SK_1 --codes \"...\"]"}
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp authenticate! do
    token =
      System.get_env("STEWARD_API_TOKEN") ||
        Mix.raise("STEWARD_API_TOKEN must contain an individual steward bearer token")

    case Api.Auth.authenticate(["Bearer #{token}"], :steward) do
      {:ok, principal, :bearer} -> principal
      _ -> Mix.raise("STEWARD_API_TOKEN is not a valid steward credential")
    end
  end

  defp attach_case(%{"kind" => kind, "keys" => keys} = decision)
       when kind in ["approve_merge", "reject_merge"] do
    sorted = Enum.sort(keys)
    review = Enum.find(Api.Steward.queue().merges, &(Enum.sort(&1.keys) == sorted))
    put_case(decision, review)
  end

  defp attach_case(%{"kind" => "resolve_attribute", "key" => key, "field" => field} = decision) do
    review = Enum.find(Api.Steward.queue().attributes, &(&1.key == key and &1.field == field))
    put_case(decision, review)
  end

  defp attach_case(%{"kind" => "split", "key" => key} = decision) do
    review = Enum.find(Api.Steward.queue().repairs, &(&1.key == key))
    put_case(decision, review)
  end

  defp attach_case(decision), do: decision

  defp put_case(decision, nil), do: decision

  defp put_case(decision, review) do
    decision
    |> Map.put("case_id", review.case_id)
    |> Map.put("evidence_offset", review.evidence_offset)
  end
end
