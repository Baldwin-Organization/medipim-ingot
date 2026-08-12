defmodule Api.Codec do
  @moduledoc """
  Explicit JSON encoding for events and projection rows.

  Engine values contain tuples, atoms, sets, dates, and nested event structs. Small tagged JSON
  values preserve those types without opaque Erlang terms. Struct and atom decoding uses existing
  modules/atoms only, so database content cannot create atoms or choose arbitrary modules.
  """

  @event_modules [
    Events.ClaimAsserted,
    Events.SourceRecordRevised,
    Events.SourceRecordKeyBound,
    Events.IdentityMinted,
    Events.IdentityMembersChanged,
    Events.IdentitiesMerged,
    Events.IdentitySplit,
    Events.IdentityRetracted,
    Events.LegacyIdAssigned,
    Events.ConflictFlagged,
    Events.MergeProposed,
    Events.ConflictResolved,
    Events.ReviewCaseOpened,
    Events.ReviewCaseEndorsed
  ]

  @modules_by_name Map.new(@event_modules, &{inspect(&1), &1})
  @atom_vocabulary_modules [
    CodeRegistry,
    Codes,
    # ConflictFlagged subject tags (:identity_conflict, :identity_swap) live only here, and a
    # cold rebuild can decode them before any write has loaded the module.
    IdentityLedger,
    Lanes,
    Relations,
    SourceRecords,
    Stewardship,
    Priority,
    Survivorship,
    Api.State,
    Api.ReviewCases
  ]

  def encode!(term), do: term |> encode_value() |> JSON.encode!()
  def decode!(json) when is_binary(json), do: json |> JSON.decode!() |> decode_value()

  @doc false
  def decode_legacy!(<<131, _::binary>> = binary), do: :erlang.binary_to_term(binary, [:safe])

  @doc "Short type tag for the events table — e.g. \"ClaimAsserted\", \"IdentitiesMerged\"."
  def type(%mod{}), do: mod |> Module.split() |> List.last()

  defp encode_value(%DateTime{} = value),
    do: %{"$type" => "datetime", "value" => DateTime.to_iso8601(value)}

  defp encode_value(%Date{} = value),
    do: %{"$type" => "date", "value" => Date.to_iso8601(value)}

  defp encode_value(%MapSet{} = value),
    do: %{"$type" => "set", "values" => value |> Enum.sort() |> Enum.map(&encode_value/1)}

  defp encode_value(%module{} = value) when module in @event_modules,
    do: %{
      "$type" => "struct",
      "module" => inspect(module),
      "fields" =>
        value
        |> Map.from_struct()
        |> Map.new(fn {field, item} -> {Atom.to_string(field), encode_value(item)} end)
    }

  defp encode_value(value) when is_tuple(value),
    do: %{"$type" => "tuple", "values" => value |> Tuple.to_list() |> Enum.map(&encode_value/1)}

  defp encode_value(value) when is_atom(value) and value not in [true, false, nil],
    do: %{"$type" => "atom", "value" => Atom.to_string(value)}

  defp encode_value(value) when is_map(value) do
    pairs =
      value
      |> Enum.map(fn {key, item} -> [encode_value(key), encode_value(item)] end)
      |> Enum.sort_by(&JSON.encode!/1)

    %{"$type" => "map", "entries" => pairs}
  end

  defp encode_value(value) when is_list(value), do: Enum.map(value, &encode_value/1)
  defp encode_value(value), do: value

  defp decode_value(%{"$type" => "datetime", "value" => value}) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end

  defp decode_value(%{"$type" => "date", "value" => value}), do: Date.from_iso8601!(value)

  defp decode_value(%{"$type" => "set", "values" => values}),
    do: values |> Enum.map(&decode_value/1) |> MapSet.new()

  defp decode_value(%{"$type" => "tuple", "values" => values}),
    do: values |> Enum.map(&decode_value/1) |> List.to_tuple()

  defp decode_value(%{"$type" => "atom", "value" => value}) do
    Enum.each(@atom_vocabulary_modules, &Code.ensure_loaded!/1)
    String.to_existing_atom(value)
  end

  defp decode_value(%{"$type" => "map", "entries" => entries}) do
    Map.new(entries, fn [key, value] -> {decode_value(key), decode_value(value)} end)
  end

  defp decode_value(%{"$type" => "struct", "module" => name, "fields" => fields}) do
    module = Map.fetch!(@modules_by_name, name)

    decoded =
      case fields do
        %{"$type" => "map"} ->
          decode_value(fields)

        fields ->
          Map.new(fields, fn {field, value} ->
            {String.to_existing_atom(field), decode_value(value)}
          end)
      end

    struct!(module, decoded)
  end

  defp decode_value(value) when is_list(value), do: Enum.map(value, &decode_value/1)
  defp decode_value(value), do: value
end
