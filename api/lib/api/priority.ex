alias GoldenRecord.{Priority}

defmodule Api.Priority do
  @moduledoc """
  Survivorship priority shared by reads, dry-run, and steward surfaces.

  With no config, the policy is intentionally empty: ties surface as conflicts for a steward
  rather than being auto-decided. Production can set `:source_priority` to:

      %{"fields" => %{"name" => [["manufacturer"], ["supplier"]]},
        "default" => [["manufacturer"], ["supplier"]]}
  """

  def empty, do: Priority.new(%{}, [])

  def current do
    case Application.get_env(:golden_record_api, :source_priority) do
      nil -> empty()
      config -> from_config(config)
    end
  end

  defp from_config(config) when is_map(config) do
    fields = Map.get(config, "fields") || Map.get(config, :fields) || %{}
    default = Map.get(config, "default") || Map.get(config, :default) || []
    Priority.new(fields, default)
  end
end
