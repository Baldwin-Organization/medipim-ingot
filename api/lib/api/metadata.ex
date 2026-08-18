alias GoldenRecord.{Lanes, Relations}

defmodule Api.Metadata do
  @moduledoc "Wire-safe registry and decision-policy metadata for API clients."

  def current do
    registry_schemes =
      CodeRegistry.table()
      |> Enum.map(fn {wire_name, {scheme, class}} ->
        %{
          wire_name: wire_name,
          canonical_name: to_string(scheme),
          class: to_string(class),
          lane: scheme |> Lanes.lane_of_scheme() |> lane_name()
        }
      end)

    declared_wire_names = MapSet.new(registry_schemes, & &1.wire_name)

    engine_schemes =
      [
        {"mpn", "mpn", "external_ref"},
        {"supplier_ref", "supplier_ref", "external_ref"},
        {"ean", "gtin", "identity"},
        {"upc", "gtin", "identity"},
        {"cas", "cas", "identity"},
        {"unii", "unii", "identity"},
        {"substance_id", "substance_id", "identity"},
        {"text_id", "text_id", "identity"},
        {"asset_id", "asset_id", "identity"},
        {"leaflet_id", "leaflet_id", "identity"},
        {"uuid", "uuid", "identity"}
      ]
      |> Enum.reject(fn {wire_name, _, _} -> MapSet.member?(declared_wire_names, wire_name) end)
      |> Enum.map(fn {wire_name, canonical_name, class} ->
        %{
          wire_name: wire_name,
          canonical_name: canonical_name,
          class: class,
          lane:
            wire_name
            |> CodeRegistry.engine_scheme()
            |> Lanes.lane_of_scheme()
            |> lane_name()
        }
      end)

    schemes =
      (registry_schemes ++ engine_schemes)
      |> Enum.sort_by(&{&1.canonical_name, &1.wire_name})

    relations =
      Relations.signatures()
      |> Enum.map(fn {name, {from, to}} ->
        %{
          name: to_string(name),
          from: Enum.map(from, &to_string/1),
          to: to && Enum.map(to, &to_string/1)
        }
      end)
      |> Enum.sort_by(& &1.name)

    %{
      schema_version: "1",
      schemes: schemes,
      relations: relations,
      survivorship: %{
        configured: Application.get_env(:golden_record_api, :source_priority) != nil,
        source_priority: Application.get_env(:golden_record_api, :source_priority),
        unresolved_ties: "needs_review"
      },
      review_policy: %{
        merge_approvals: 2,
        split_approvals: 2,
        suppress_approvals: 2,
        distinct_authenticated_principals: true,
        evidence_offset_required: true
      },
      temporal: %{
        known_at: "RFC3339 timestamp",
        effective_at: "ISO 8601 date",
        valid_intervals: "[valid_from, valid_to)"
      }
    }
  end

  defp lane_name(nil), do: nil
  defp lane_name(lane), do: to_string(lane)
end
