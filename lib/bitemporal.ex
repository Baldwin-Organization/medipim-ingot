defmodule Bitemporal do
  @moduledoc false

  def known?(event, known_at), do: compare(Map.fetch!(event, :recorded_at), known_at) != :gt

  def effective?(event, %Date{} = effective_at) do
    from = Map.get(event, :valid_from) || effective_date(Map.fetch!(event, :recorded_at))
    until_date = Map.get(event, :valid_to)

    Date.compare(from, effective_at) != :gt and
      (is_nil(until_date) or Date.compare(effective_at, until_date) == :lt)
  end

  def compare(left, right), do: DateTime.compare(to_datetime(left), to_datetime(right))

  def sort_key(value) do
    value = to_datetime(value)
    {DateTime.to_unix(value, :microsecond), value.microsecond}
  end

  def effective_date(%Date{} = date), do: date
  def effective_date(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  def effective_date(epoch) when is_integer(epoch), do: epoch |> DateTime.from_unix!() |> DateTime.to_date()

  def to_datetime(%DateTime{} = datetime), do: DateTime.shift_zone!(datetime, "Etc/UTC")

  def to_datetime(%Date{} = date),
    do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  def to_datetime(epoch) when is_integer(epoch), do: DateTime.from_unix!(epoch)
end
