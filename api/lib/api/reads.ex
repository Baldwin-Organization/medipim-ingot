defmodule Api.Reads do
  @moduledoc """
  The Product API reads. Current product/code reads use indexed per-key projections; historical
  two-clock reads fold the immutable log because time travel is rarer and correctness comes first.

  A legacy id keeps answering across merges (followed to the survivor, with `merged_from` saying
  where it came from) — the backwards-compatibility contract.
  """

  @doc "The product a legacy medipim id answers to today. `{:ok, view} | :not_found`."
  def product(legacy_id) when is_integer(legacy_id) do
    Api.Store.refresh_if_needed!()
    known_at = DateTime.utc_now()
    effective_at = Date.utc_today()

    case Api.ReadModels.golden_by_legacy(legacy_id) do
      {:ok, view, original, current} ->
        {:ok,
         view
         |> Map.put(:legacy_id, legacy_id)
         |> Map.put(:merged_from, if(current != original, do: original))
         |> Map.put(:known_at, known_at)
         |> Map.put(:effective_at, effective_at)}

      :not_found ->
        :not_found
    end
  end

  @doc "A product under independent system-knowledge and source-effective clocks."
  def product_at(legacy_id, known_at, %Date{} = effective_at) when is_integer(legacy_id) do
    log = Api.Store.log()
    known = Enum.filter(log, &Bitemporal.known?(&1, known_at))

    case key_for_log(known, legacy_id) do
      nil ->
        :not_found

      original ->
        key = follow_log(known, original, effective_at)
        view = project_one_at(log, known_at, effective_at, key)

        {:ok,
         view
         |> Map.put(:legacy_id, legacy_id)
         |> Map.put(:merged_from, if(key != original, do: original))
         |> Map.put(:known_at, Bitemporal.to_datetime(known_at))
         |> Map.put(:effective_at, effective_at)}
    end
  end

  @doc "Compatibility read with both clocks set to the same calendar date."
  def product_as_of(legacy_id, %Date{} = date) when is_integer(legacy_id) do
    case product_at(legacy_id, date, date) do
      {:ok, %{codes: []} = view} ->
        {:not_found_as_of, view.key}

      {:ok, view} ->
        {:ok, Map.put(view, :as_of, date)}

      :not_found ->
        case key_for_log(Api.Store.log(), legacy_id) do
          nil -> :not_found
          future_key -> {:not_found_as_of, future_key}
        end
    end
  end

  @doc "Every product carrying this code (a legitimately shared code can match several)."
  def by_code(scheme, value) do
    Api.Store.refresh_if_needed!()
    known_at = DateTime.utc_now()
    effective_at = Date.utc_today()
    code = Codes.canonicalize({CodeRegistry.engine_scheme(scheme), value})

    case Api.ReadModels.golden_by_code(elem(code, 0), elem(code, 1)) do
      {:ok, products} ->
        {:ok,
         %{
           code: Api.Views.code(code),
           known_at: known_at,
           effective_at: effective_at,
           products: products
         }}

      :not_found ->
        :not_found
    end
  end

  def by_code_at(scheme, value, known_at, %Date{} = effective_at) do
    log = Api.Store.log()
    temporal = History.state_bitemporal(log, known_at, effective_at)
    code = Codes.canonicalize({CodeRegistry.engine_scheme(scheme), value})

    matches =
      for {key, codes} <- temporal.members,
          Lanes.lane_of_key(key) == :product,
          MapSet.member?(codes, code) do
        project_one_at(log, known_at, effective_at, key)
        |> Map.put(:legacy_id, legacy_of_log(log, known_at, key))
      end

    case matches do
      [] ->
        :not_found

      views ->
        {:ok,
         %{
           code: Api.Views.code(code),
           known_at: Bitemporal.to_datetime(known_at),
           effective_at: effective_at,
           products: Enum.sort_by(views, & &1.key)
         }}
    end
  end

  @doc "Decoded events after `offset`, as feed views — medipim's polling substrate."
  def changes(offset, limit) when is_integer(offset) do
    events = Api.Store.events_since(offset, limit)

    %{
      events: Enum.map(events, &Api.Views.feed_event/1),
      next: events |> Enum.map(& &1.order) |> Enum.max(fn -> offset end),
      count: length(events)
    }
  end

  @doc "The current accepted revision of one upstream source record."
  def source_record(source, ref) do
    Api.Store.refresh_if_needed!()

    case Api.ReadModels.source_record(source, ref) do
      {:ok, record} ->
        identity = Enum.find(record.claims, &(&1.kind == :identity))
        {:ok, lane} = Lanes.of_claim(identity)

        key =
          source
          |> Api.ReadModels.source_record_key(ref, lane)
          |> Api.ReadModels.resolve_key()

        {:ok,
         %{
           source: source,
           ref: ref,
           revision: record.revision,
           operation: Atom.to_string(record.operation),
           status: if(record.active, do: "active", else: "withdrawn"),
           key: key,
           legacy_id: Api.ReadModels.legacy_for_key(key),
           known_at: DateTime.utc_now(),
           effective_at: Date.utc_today(),
           recorded_at: Bitemporal.to_datetime(record.recorded_at),
           valid_from: record.valid_from,
           valid_to: record.valid_to,
           claims: Enum.map(record.claims, &source_claim/1)
         }}

      :not_found ->
        :not_found
    end
  end

  def source_record_at(source, ref, known_at, %Date{} = effective_at) do
    log = Api.Store.log()

    record =
      log
      |> Enum.filter(&match?(%Events.SourceRecordRevised{source: ^source, ref: ^ref}, &1))
      |> Enum.filter(&Bitemporal.known?(&1, known_at))
      |> Enum.filter(&Bitemporal.effective?(&1, effective_at))
      |> Enum.max_by(&{Bitemporal.sort_key(&1.recorded_at), &1.order || -1}, fn -> nil end)

    case record do
      nil ->
        :not_found

      record ->
        known = Enum.filter(log, &Bitemporal.known?(&1, known_at))
        identity = Enum.find(record.claims, &(&1.kind == :identity))
        {:ok, lane} = Lanes.of_claim(identity)

        binding =
          known
          |> Enum.filter(
            &match?(%Events.SourceRecordKeyBound{source: ^source, ref: ^ref, lane: ^lane}, &1)
          )
          |> Enum.max_by(&(&1.order || -1), fn -> nil end)

        key = binding && follow_log(known, binding.key, effective_at)

        {:ok,
         %{
           source: source,
           ref: ref,
           revision: record.revision,
           operation: Atom.to_string(record.operation),
           status: if(record.active, do: "active", else: "withdrawn"),
           key: key,
           legacy_id: key && legacy_of_log(log, known_at, key),
           known_at: Bitemporal.to_datetime(known_at),
           effective_at: effective_at,
           recorded_at: Bitemporal.to_datetime(record.recorded_at),
           valid_from: record.valid_from,
           valid_to: record.valid_to,
           claims: Enum.map(record.claims, &source_claim/1)
         }}
    end
  end

  # ── internals ───────────────────────────────────────────────────────────────
  defp key_for_log(known, legacy_id) do
    Enum.find_value(known, fn
      %Events.LegacyIdAssigned{key: key, legacy_id: ^legacy_id} -> key
      _ -> nil
    end)
  end

  defp legacy_of_log(log, known_at, key) do
    log
    |> Enum.filter(&Bitemporal.known?(&1, known_at))
    |> Enum.find_value(fn
      %Events.LegacyIdAssigned{key: ^key, legacy_id: id} -> id
      _ -> nil
    end)
  end

  defp source_claim(%Events.ClaimAsserted{kind: :identity, data: data}),
    do: %{kind: "identity", codes: Enum.map(data.codes, &CanonicalClaims.code_string/1)}

  defp source_claim(%Events.ClaimAsserted{kind: :attribute, data: data}),
    do: %{
      kind: "attribute",
      code: CanonicalClaims.code_string(data.code),
      field: data.field,
      value: data.value
    }

  defp source_claim(%Events.ClaimAsserted{kind: :grouping, data: data}),
    do: %{kind: "grouping", code: CanonicalClaims.code_string(data.code), product: data.product}

  defp source_claim(%Events.ClaimAsserted{kind: :media, data: data}),
    do: %{
      kind: "media",
      asset: elem(data.asset, 1),
      target: CanonicalClaims.code_string(data.target),
      role: data.role,
      uri: data.uri
    }

  defp source_claim(%Events.ClaimAsserted{kind: :edge, data: data}),
    do: %{
      kind: "edge",
      from: CanonicalClaims.code_string(data.from),
      relation: data.relation,
      to: CanonicalClaims.code_string(data.to)
    }

  defp project_one_at(log, known_at, effective_at, key) do
    temporal = History.state_bitemporal(log, known_at, effective_at)

    members =
      temporal.members
      |> Enum.filter(fn {member_key, _codes} ->
        member_key == key or Lanes.lane_of_key(member_key) != :product
      end)
      |> Map.new()

    case Catalog.project(
           members,
           temporal.claims,
           Api.Priority.current(),
           temporal.overrides
         ) do
      [] ->
        %{
          key: key,
          codes: [],
          attributes: [],
          media: [],
          status: status_of_log(log, known_at, effective_at, key)
        }

      groups ->
        variant = groups |> Enum.flat_map(& &1.variants) |> Enum.find(&(&1.key == key))

        variant
        |> Api.Views.variant()
        |> Map.put(:status, status_of_log(log, known_at, effective_at, key))
    end
  end

  defp status_of_log(log, known_at, effective_at, key) do
    temporal = History.state_bitemporal(log, known_at, effective_at)
    known = Enum.filter(log, &Bitemporal.known?(&1, known_at))

    cond do
      Map.has_key?(temporal.members, key) -> "active"
      follow_log(known, key, effective_at) != key -> "merged"
      withdrawn_key?(known, effective_at, key) -> "withdrawn"
      true -> "unknown"
    end
  end

  defp withdrawn_key?(known, effective_at, key) do
    bindings =
      for %Events.SourceRecordKeyBound{} = binding <- known, into: %{} do
        {{binding.source, binding.ref}, binding.key}
      end

    known
    |> Enum.filter(&match?(%Events.SourceRecordRevised{}, &1))
    |> Enum.filter(&Bitemporal.effective?(&1, effective_at))
    |> Enum.group_by(&{&1.source, &1.ref})
    |> Enum.any?(fn {record, revisions} ->
      latest = Enum.max_by(revisions, &{Bitemporal.sort_key(&1.recorded_at), &1.order || -1})

      latest.active == false and
        follow_log(known, Map.get(bindings, record), effective_at) == key
    end)
  end

  defp follow_log(_known, nil, _effective_at), do: nil

  defp follow_log(known, key, effective_at) do
    redirect =
      Enum.find_value(known, fn
        %Events.IdentitiesMerged{from: from, into: into} = merge ->
          if key in from and key != into and Bitemporal.effective?(merge, effective_at), do: into

        _ ->
          nil
      end)

    if redirect, do: follow_log(known, redirect, effective_at), else: key
  end
end
