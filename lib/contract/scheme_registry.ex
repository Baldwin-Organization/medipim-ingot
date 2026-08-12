defmodule SchemeRegistry do
  @moduledoc """
  Runtime rules for code schemes and typed edge relations.

  Scheme and relation names remain strings: registry documents are trusted configuration, but
  they are still not allowed to create atoms. Only the fixed engine vocabulary (classes, lanes,
  bridge grades, normalizer kinds, and checksums) is converted through explicit lookup tables.
  """

  defmodule Scheme do
    @enforce_keys [:name, :class, :lane, :bridge_grade, :normalizer, :checksum]
    defstruct [:name, :class, :lane, :bridge_grade, :normalizer, :checksum, :equivalence_family, aliases: []]
  end

  defmodule Relation do
    @enforce_keys [:name, :from, :to]
    defstruct [:name, :from, :to]
  end

  @enforce_keys [:schemes, :aliases, :relations]
  defstruct [:schemes, :aliases, :relations]

  @name ~r/^[a-z][a-z0-9_]*$/
  @classes %{
    "identity" => :identity,
    "external_ref" => :external_ref,
    "attribute" => :attribute,
    "entity_id" => :entity_id
  }
  @lanes %{
    "product" => :product,
    "substance" => :substance,
    "description" => :description,
    "media" => :media
  }
  @bridge_grades %{"national" => :national, "barcode" => :barcode, "none" => :none}
  @checksums %{"none" => :none, "gtin_mod10" => :gtin_mod10, "mod-11" => :mod_11}

  def empty, do: %__MODULE__{schemes: %{}, aliases: %{}, relations: %{}}

  @doc "Load and validate a decoded scheme-registry document."
  def from_map(%{"schema_version" => "1", "schemes" => schemes} = document) when is_list(schemes) do
    {parsed_schemes, scheme_errors} = parse_all(schemes, &parse_scheme/2)
    {parsed_relations, relation_errors} = parse_all(Map.get(document, "relations", []), &parse_relation/2)
    alias_errors = alias_errors(parsed_schemes)
    duplicate_relation_errors = duplicate_name_errors(parsed_relations, "relation")
    errors = scheme_errors ++ relation_errors ++ alias_errors ++ duplicate_relation_errors

    if errors == [] do
      scheme_map = Map.new(parsed_schemes, &{&1.name, &1})

      aliases =
        for scheme <- parsed_schemes,
            spelling <- [scheme.name | scheme.aliases],
            into: %{},
            do: {spelling, scheme.name}

      {:ok,
       %__MODULE__{
         schemes: scheme_map,
         aliases: aliases,
         relations: Map.new(parsed_relations, &{&1.name, &1})
       }}
    else
      {:error, errors}
    end
  end

  def from_map(%{"schema_version" => version}),
    do: {:error, ["unsupported schema_version #{inspect(version)}"]}

  def from_map(_), do: {:error, [~s(registry must contain schema_version "1" and a schemes array)]}

  def from_map!(document) do
    case from_map(document) do
      {:ok, registry} -> registry
      {:error, errors} -> raise ArgumentError, Enum.join(errors, "; ")
    end
  end

  def from_json(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, document} -> from_map(document)
      {:error, reason} -> {:error, ["invalid registry JSON: #{inspect(reason)}"]}
    end
  end

  def load(path) do
    case File.read(path) do
      {:ok, json} -> from_json(json)
      {:error, reason} -> {:error, ["cannot read registry: #{:file.format_error(reason)}"]}
    end
  end

  def load!(path) do
    case load(path) do
      {:ok, registry} -> registry
      {:error, errors} -> raise ArgumentError, Enum.join(errors, "; ")
    end
  end

  @doc "Canonical registry name for a scheme name or alias; nil when undeclared."
  def canonical_name(%__MODULE__{aliases: aliases}, name), do: Map.get(aliases, scheme_name(name))

  @doc "Declared scheme rule for a name or alias."
  def scheme(%__MODULE__{} = registry, name) do
    with canonical when not is_nil(canonical) <- canonical_name(registry, name) do
      Map.get(registry.schemes, canonical)
    end
  end

  def class(registry, name), do: field(registry, name, :class)
  def lane(registry, name), do: field(registry, name, :lane)
  def bridge_grade(registry, name), do: field(registry, name, :bridge_grade)
  def normalizer(registry, name), do: field(registry, name, :normalizer)
  def checksum(registry, name), do: field(registry, name, :checksum)

  @doc "Declared relation rule; names remain strings."
  def relation(%__MODULE__{relations: relations}, name) do
    case Map.fetch(relations, scheme_name(name)) do
      {:ok, %Relation{} = relation} -> {:ok, Map.from_struct(relation)}
      :error -> :error
    end
  end

  defp field(registry, name, field) do
    case scheme(registry, name) do
      %Scheme{} = scheme -> Map.fetch!(scheme, field)
      nil -> nil
    end
  end

  defp parse_all(items, parser) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {item, index}, {values, errors} ->
      case parser.(item, index) do
        {:ok, value} -> {[value | values], errors}
        {:error, item_errors} -> {values, errors ++ item_errors}
      end
    end)
    |> then(fn {values, errors} -> {Enum.reverse(values), errors} end)
  end

  defp parse_all(value, _parser), do: {[], ["relations must be an array, got #{inspect(value)}"]}

  defp parse_scheme(%{"name" => name, "class" => class} = raw, index) do
    aliases = Map.get(raw, "aliases", [])

    errors =
      valid_name(name, "scheme[#{index}].name") ++
        valid_enum(class, @classes, "scheme #{inspect(name)} class") ++
        valid_enum(Map.get(raw, "entity_type", "product"), @lanes, "scheme #{inspect(name)} entity_type") ++
        valid_enum(
          Map.get(raw, "bridge_grade", "none"),
          @bridge_grades,
          "scheme #{inspect(name)} bridge_grade"
        ) ++
        valid_enum(Map.get(raw, "checksum", "none"), @checksums, "scheme #{inspect(name)} checksum") ++
        valid_aliases(aliases, name) ++
        valid_equivalence_family(Map.get(raw, "equivalence_family"), name) ++
        normalizer_errors(Map.get(raw, "normalizer", %{"kind" => "trim"}), name)

    if errors == [] do
      {:ok,
       %Scheme{
         name: name,
         class: Map.fetch!(@classes, class),
         lane: Map.fetch!(@lanes, Map.get(raw, "entity_type", "product")),
         bridge_grade: Map.fetch!(@bridge_grades, Map.get(raw, "bridge_grade", "none")),
         normalizer: parse_normalizer(Map.get(raw, "normalizer", %{"kind" => "trim"})),
         checksum: Map.fetch!(@checksums, Map.get(raw, "checksum", "none")),
         equivalence_family: Map.get(raw, "equivalence_family"),
         aliases: aliases
       }}
    else
      {:error, errors}
    end
  end

  defp parse_scheme(raw, index),
    do: {:error, ["scheme[#{index}] must be an object with name and class, got #{inspect(raw)}"]}

  defp parse_relation(%{"name" => name, "from" => from, "to" => to}, index) do
    errors =
      valid_name(name, "relation[#{index}].name") ++
        valid_lanes(from, "relation #{inspect(name)} from") ++
        if(to == nil, do: [], else: valid_lanes(to, "relation #{inspect(name)} to"))

    if errors == [] do
      {:ok,
       %Relation{
         name: name,
         from: Enum.map(from, &Map.fetch!(@lanes, &1)),
         to: if(to == nil, do: nil, else: Enum.map(to, &Map.fetch!(@lanes, &1)))
       }}
    else
      {:error, errors}
    end
  end

  defp parse_relation(raw, index),
    do: {:error, ["relation[#{index}] must contain name, from, and to, got #{inspect(raw)}"]}

  defp valid_name(value, field) when is_binary(value) do
    if Regex.match?(@name, value),
      do: [],
      else: ["#{field} must be lowercase snake_case, got #{inspect(value)}"]
  end

  defp valid_name(value, field), do: ["#{field} must be a string, got #{inspect(value)}"]

  defp valid_enum(value, allowed, field) do
    if Map.has_key?(allowed, value),
      do: [],
      else: ["#{field} has unknown value #{inspect(value)}"]
  end

  defp valid_aliases(aliases, scheme) when is_list(aliases) do
    Enum.flat_map(aliases, &valid_name(&1, "scheme #{inspect(scheme)} alias"))
  end

  defp valid_aliases(value, scheme),
    do: ["scheme #{inspect(scheme)} aliases must be an array, got #{inspect(value)}"]

  defp valid_equivalence_family(nil, _scheme), do: []

  defp valid_equivalence_family(value, scheme),
    do: valid_name(value, "scheme #{inspect(scheme)} equivalence_family")

  defp valid_lanes([_ | _] = lanes, field) do
    Enum.flat_map(lanes, fn lane ->
      if Map.has_key?(@lanes, lane), do: [], else: ["#{field} contains unknown lane #{inspect(lane)}"]
    end)
  end

  defp valid_lanes(value, field), do: ["#{field} must be a non-empty lane array, got #{inspect(value)}"]

  defp normalizer_errors(%{"kind" => "trim"}, _scheme), do: []
  defp normalizer_errors(%{"kind" => "gtin"}, _scheme), do: []

  defp normalizer_errors(%{"kind" => "pad_left", "width" => width}, _scheme)
       when is_integer(width) and width > 0,
       do: []

  defp normalizer_errors(value, scheme),
    do: ["scheme #{inspect(scheme)} has invalid normalizer #{inspect(value)}"]

  defp parse_normalizer(%{"kind" => "trim"}), do: :trim
  defp parse_normalizer(%{"kind" => "gtin"}), do: :gtin
  defp parse_normalizer(%{"kind" => "pad_left", "width" => width}), do: {:pad_left, width}

  defp alias_errors(schemes) do
    schemes
    |> Enum.flat_map(fn scheme -> Enum.map([scheme.name | scheme.aliases], &{&1, scheme.name}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {spelling, owners} ->
      if length(owners) == 1,
        do: [],
        else: [~s(alias #{inspect(spelling)} is declared more than once by #{inspect(Enum.sort(owners))})]
    end)
  end

  defp duplicate_name_errors(items, kind) do
    items
    |> Enum.group_by(& &1.name)
    |> Enum.flat_map(fn {name, entries} ->
      if length(entries) == 1, do: [], else: ["#{kind} #{inspect(name)} is declared more than once"]
    end)
  end

  defp scheme_name(name) when is_atom(name), do: Atom.to_string(name)
  defp scheme_name(name) when is_binary(name), do: name
end
