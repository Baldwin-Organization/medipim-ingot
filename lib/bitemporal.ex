defmodule Bitemporal do
  @moduledoc false

  def known?(event, known_at), do: compare(Map.fetch!(event, :recorded_at), known_at) != :gt

  # Temporals reach here as Date, DateTime or unix seconds — the backfill carries contract-C
  # unix-second stamps, the live wire carries ISO dates. Every other function in this module
  # already normalises through effective_date/1; this one used to compare raw, so a backfilled
  # claim raised FunctionClauseError inside Date.compare/2 the moment anything asked for it
  # bitemporally.
  def effective?(event, %Date{} = effective_at) do
    from =
      case Map.get(event, :valid_from) do
        nil -> effective_date(Map.fetch!(event, :recorded_at))
        value -> effective_date(value)
      end

    until_date = Map.get(event, :valid_to)

    Date.compare(from, effective_at) != :gt and
      (is_nil(until_date) or Date.compare(effective_at, effective_date(until_date)) == :lt)
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
