defmodule GoldenRecord.Priority do
  @enforce_keys [:table, :default]
  defstruct [:table, :default]

  def new(table, default), do: %__MODULE__{table: table, default: default}

  def rank(%__MODULE__{table: table, default: default}, dimension, source) do
    tiers = Map.get(table, dimension, default)
    Enum.find_index(tiers, fn tier -> source in tier end) || :infinity
  end
end
