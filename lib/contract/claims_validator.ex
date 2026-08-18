# lib/contract/claims_validator.ex — the executable canonical-claims contract (bead gr-f6t).
#
# Hand-rolled, stdlib-only validation of a decoded claims batch (the value of the "claims" key
# in a POST /v1/claims submission) against docs/CLAIMS_CONTRACT.md. The contract/*.schema.json
# files are the spec artifacts; this module is the contract a customer's mapping script actually
# hits — so every finding is actionable: %{index, field, error}, zero-based index into the batch.
#
# Two severities, mirroring what the engine does at the boundary:
#
#   * errors   — the engine REJECTS these (whole batch, nothing partial enters the log):
#                wrong shapes, unknown kinds, missing/mistyped fields, malformed codes and dates.
#   * warnings — the engine ACCEPTS these but the mapping is probably wrong: unknown schemes
#                (pass through opaque + non-bridging), GTIN-family values that are not
#                GTIN-shaped or fail the mod-10 check digit (checksums are advisory — open
#                question 2 in the spec), media roles that silently become "secondary".

alias GoldenRecord.{Codes, Lanes, Relations}

defmodule ClaimsValidator do
  @moduledoc """
  Contract-level validator for canonical claims JSON (`docs/CLAIMS_CONTRACT.md`).

  `validate/1` takes the decoded claims batch — a list of claim maps — and returns
  `{:ok, warnings}` or `{:error, errors}`, both lists of `%{index, field, error}` where `index`
  is the zero-based position of the offending claim (`nil` for batch-level failures), `field`
  the offending field (`nil` when the claim as a whole is malformed), and `error` a
  human-readable reason. Messages are NOT machine-stable — match on `index`/`field`.

  Structural rules reject (the engine refuses the batch); semantic advisories warn (the engine
  accepts, but the mapping likely has a bug): unknown schemes, GTIN canonicalization/checksum
  failures, non-enum media roles.
  """

  @kinds ~w(identity attribute media grouping edge)
  @gtin_family [:gtin, :ean, :upc]

  @doc """
  Validate a decoded claims batch (a list of claim maps).

  Returns `{:ok, warnings}` when every claim is structurally valid, or `{:error, errors}` when
  any claim rejects — one finding per offending field, shaped `%{index, field, error}`.
  """
  def validate(claims), do: validate(claims, [])

  def validate(claims, opts) when is_list(claims) do
    registry = Keyword.get(opts, :scheme_registry)

    findings =
      claims
      |> Enum.with_index()
      |> Enum.flat_map(fn {claim, index} -> claim_findings(claim, index, registry) end)

    case Enum.split_with(findings, &match?({:error, _}, &1)) do
      {[], warnings} -> {:ok, Enum.map(warnings, fn {:warning, w} -> w end)}
      {errors, _} -> {:error, Enum.map(errors, fn {:error, e} -> e end)}
    end
  end

  def validate(_, _opts),
    do: {:error, [%{index: nil, field: nil, error: "claims must be a list"}]}

  # ── one claim ───────────────────────────────────────────────────────────────
  defp claim_findings(%{"kind" => kind} = claim, index, registry) when kind in @kinds do
    fields(kind, claim, index, registry) ++ temporal_interval(claim, index)
  end

  defp claim_findings(%{"kind" => kind}, index, _registry),
    do: [error(index, "kind", "unknown kind #{inspect(kind)}")]

  defp claim_findings(_, index, _registry),
    do: [error(index, nil, "claim must be an object with a kind")]

  # ── per-kind required fields (spec: "Claim shape" + contract/claims.schema.json) ─
  defp fields("identity", claim, index, registry) do
    non_empty_string(claim, "source", index) ++
      non_empty_string(claim, "ref", index) ++
      codes(claim, index, registry) ++
      entity(claim, index) ++
      lane_findings(claim, index, registry)
  end

  defp fields("attribute", claim, index, registry) do
    non_empty_string(claim, "source", index) ++
      code(claim, "code", index, registry) ++
      non_empty_string(claim, "field", index) ++
      scalar(claim, "value", index)
  end

  defp fields("media", claim, index, registry) do
    non_empty_string(claim, "source", index) ++
      non_empty_string(claim, "asset", index) ++
      code(claim, "target", index, registry) ++
      non_empty_string(claim, "uri", index) ++
      role(claim, index)
  end

  defp fields("grouping", claim, index, registry) do
    non_empty_string(claim, "source", index) ++
      code(claim, "code", index, registry) ++
      integer(claim, "product", index)
  end

  defp fields("edge", claim, index, registry) do
    non_empty_string(claim, "source", index) ++
      code(claim, "from", index, registry) ++
      code(claim, "to", index, registry) ++
      relation(claim, index, registry)
  end

  # ── lane & relation rules (gr-dig) ──────────────────────────────────────────
  # Identity codes mixing two lanes reject — a claim cannot be a product AND a substance. The
  # check runs only when every code parses (code findings already cover malformed ones).
  defp lane_findings(%{"codes" => [_ | _] = list}, index, registry) do
    parsed = Enum.map(list, &CanonicalClaims.parse_code(&1, registry))

    with true <- Enum.all?(parsed, &match?({:ok, _}, &1)) do
      parsed
      |> Enum.map(fn {:ok, {scheme, _}} -> Lanes.lane_of_scheme(scheme, registry) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> case do
        [_, _ | _] = lanes ->
          [
            error(
              index,
              "codes",
              "codes mix entity lanes #{inspect(Enum.sort(lanes))} — one record, one lane"
            )
          ]

        _ ->
          []
      end
    else
      _ -> []
    end
  end

  defp lane_findings(_claim, _index, _registry), do: []

  defp entity(claim, index) do
    case claim do
      %{"entity" => name} when is_binary(name) ->
        case Lanes.parse(name) do
          {:ok, _lane} -> []
          :error -> [error(index, "entity", "unknown entity lane #{inspect(name)}")]
        end

      %{"entity" => value} ->
        [error(index, "entity", "entity must be a lane name string, got #{inspect(value)}")]

      # No entity, but every code is the lane-neutral uuid scheme — the claim carries no lane of
      # its own, so it MUST name one. Without this, Lanes.of_claim/1 silently defaults it to
      # :product (the contract makes entity required exactly here).
      %{"codes" => [_ | _] = list} ->
        if lane_neutral_codes?(list, nil) do
          [error(index, "entity", "entity is required when every code is the lane-neutral uuid scheme")]
        else
          []
        end

      _ ->
        []
    end
  end

  # True only when every code parses AND every code's scheme is lane-neutral (`:uuid` today —
  # Lanes.lane_of_scheme/1 returns nil). Malformed codes are already reported by codes/2.
  defp lane_neutral_codes?(list, registry) do
    Enum.all?(list, fn raw ->
      case CanonicalClaims.parse_code(raw, registry) do
        {:ok, {scheme, _}} -> Lanes.lane_of_scheme(scheme, registry) == nil
        _ -> false
      end
    end)
  end

  # The relation must exist in the registry AND its lane signature must hold (the design's
  # contract rule: a mismatched endpoint is an error, not a warning).
  defp relation(claim, index, registry) do
    with %{"relation" => name} when is_binary(name) <- claim,
         {:ok, rel} <- Relations.parse(name, registry) do
      signature(claim, rel, index, registry)
    else
      %{"relation" => value} -> [error(index, "relation", "unknown relation #{inspect(value)}")]
      :error -> [error(index, "relation", "unknown relation #{inspect(claim["relation"])}")]
      _ -> [error(index, "relation", "relation is required")]
    end
  end

  defp signature(claim, rel, index, registry) do
    with {:ok, from} <- CanonicalClaims.parse_code(Map.get(claim, "from", ""), registry),
         {:ok, to} <- CanonicalClaims.parse_code(Map.get(claim, "to", ""), registry) do
      if Relations.valid_signature?(rel, from, to, registry) do
        []
      else
        signature =
          case registry do
            %SchemeRegistry{} ->
              case SchemeRegistry.relation(registry, rel) do
                {:ok, relation} -> {relation.from, relation.to}
                :error -> Relations.signatures()[rel]
              end

            nil ->
              Relations.signatures()[rel]
          end

        [
          error(
            index,
            "relation",
            "edge endpoints do not satisfy #{inspect(rel)}'s lane signature #{inspect(signature)}"
          )
        ]
      end
    else
      # malformed endpoint codes already reject via code/3
      _ -> []
    end
  end

  # ── field rules ─────────────────────────────────────────────────────────────
  defp non_empty_string(claim, field, index) do
    case claim do
      %{^field => value} when is_binary(value) and value != "" ->
        []

      %{^field => value} ->
        [error(index, field, "#{field} must be a non-empty string, got #{inspect(value)}")]

      _ ->
        [error(index, field, "#{field} is required")]
    end
  end

  defp scalar(claim, field, index) do
    case claim do
      %{^field => v} when is_binary(v) or is_number(v) or is_boolean(v) ->
        []

      %{^field => v} ->
        [error(index, field, "#{field} must be a string, number, or boolean, got #{inspect(v)}")]

      _ ->
        [error(index, field, "#{field} is required")]
    end
  end

  defp integer(claim, field, index) do
    case claim do
      %{^field => v} when is_integer(v) -> []
      %{^field => v} -> [error(index, field, "#{field} must be an integer, got #{inspect(v)}")]
      _ -> [error(index, field, "#{field} is required")]
    end
  end

  defp codes(claim, index, registry) do
    case claim do
      %{"codes" => list} when is_list(list) ->
        Enum.flat_map(list, &code_findings(&1, "codes", index, registry))

      %{"codes" => value} ->
        [
          error(
            index,
            "codes",
            ~s(codes must be an array of "scheme:value" strings, got #{inspect(value)})
          )
        ]

      _ ->
        [error(index, "codes", "codes is required")]
    end
  end

  defp code(claim, field, index, registry) do
    case claim do
      %{^field => raw} -> code_findings(raw, field, index, registry)
      _ -> [error(index, field, "#{field} is required")]
    end
  end

  # A code is one "scheme:value" string, split on the FIRST colon, both halves non-empty.
  defp code_findings(raw, field, index, registry) when is_binary(raw) do
    case String.split(raw, ":", parts: 2) do
      [scheme, value] when scheme != "" and value != "" ->
        scheme_advisories(scheme, value, raw, field, index, registry)

      _ ->
        [error(index, field, ~s(code must be "scheme:value", got #{inspect(raw)}))]
    end
  end

  defp code_findings(raw, field, index, _registry),
    do: [error(index, field, ~s(code must be a "scheme:value" string, got #{inspect(raw)}))]

  # ── semantic advisories — the engine accepts all of these (warnings, never errors) ─
  defp scheme_advisories(scheme, value, raw, field, index, registry) do
    declared = match?(%SchemeRegistry.Scheme{}, registry && SchemeRegistry.scheme(registry, scheme))

    case {declared, CodeRegistry.engine_scheme(scheme)} do
      {true, _engine} ->
        []

      {false, engine} when is_atom(engine) and engine in @gtin_family ->
        gtin_advisories(engine, value, raw, field, index)

      {false, :cnk} ->
        cnk_advisories(value, raw, field, index)

      {false, engine} when is_atom(engine) ->
        []

      {false, _unknown} ->
        [
          warning(
            index,
            field,
            "unknown scheme #{inspect(scheme)} in #{inspect(raw)} — accepted, but passes through as an opaque, non-bridging code"
          )
        ]
    end
  end

  defp gtin_advisories(engine, value, raw, field, index) do
    case Codes.canonicalize({engine, value}) do
      {:gtin, gtin14} = canonical when byte_size(gtin14) == 14 ->
        checksum =
          if Codes.valid_gtin?(canonical) do
            []
          else
            [
              warning(
                index,
                field,
                "#{inspect(raw)} fails the GTIN mod-10 check digit — accepted, but the code is likely mistyped"
              )
            ]
          end

        restricted =
          if Codes.restricted?(canonical) do
            [
              warning(
                index,
                field,
                "#{inspect(raw)} is a restricted circulation GTIN — accepted, but it is not globally unique and will not bridge products"
              )
            ]
          else
            []
          end

        checksum ++ restricted

      _not_gtin_shaped ->
        [
          warning(
            index,
            field,
            "#{inspect(raw)} is not GTIN-shaped (8/12/13/14 digits) — accepted untouched, but will never bridge as a GTIN"
          )
        ]
    end
  end

  # Real CNKs are 7 digits: 6 payload digits plus a Mod-10 check digit. Short fake CNKs are common
  # in tests and demos, so only real-shaped values get the checksum advisory.
  defp cnk_advisories(value, raw, field, index) do
    if value =~ ~r/^\d{7}$/ and not valid_cnk?(value) do
      [
        warning(
          index,
          field,
          "#{inspect(raw)} fails the CNK Mod-10 check digit — accepted, but the code is likely mistyped"
        )
      ]
    else
      []
    end
  end

  defp valid_cnk?(<<payload::binary-size(6), check::binary-size(1)>>),
    do: check == Integer.to_string(mod10_check_digit(payload))

  defp mod10_check_digit(payload) do
    sum =
      payload
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.reduce(0, fn {digit, index}, acc ->
        if rem(index, 2) == 0 do
          doubled = digit * 2
          acc + div(doubled, 10) + rem(doubled, 10)
        else
          acc + digit
        end
      end)

    rem(10 - rem(sum, 10), 10)
  end

  # role is forgiving in the engine: anything other than "primary" silently means secondary
  # (open question 5) — so a non-enum role is a warning, not an error.
  defp role(claim, index) do
    case claim do
      %{"role" => role} when role in ["primary", "secondary"] ->
        []

      %{"role" => role} ->
        [
          warning(
            index,
            "role",
            ~s(role #{inspect(role)} is not "primary" or "secondary" — the engine treats it as secondary)
          )
        ]

      _ ->
        []
    end
  end

  # Validity is a half-open source-effective interval: [valid_from, valid_to).
  defp temporal_interval(claim, index) do
    from = parse_date(claim, "valid_from", index)
    until_date = parse_date(claim, "valid_to", index)
    findings = elem(from, 1) ++ elem(until_date, 1)

    case {elem(from, 0), elem(until_date, 0)} do
      {%Date{} = first, %Date{} = last} ->
        if Date.before?(first, last),
          do: findings,
          else: findings ++ [error(index, "valid_to", "valid_to must be later than valid_from")]

      _ ->
        findings
    end
  end

  defp parse_date(claim, field, index) do
    case Map.fetch(claim, field) do
      :error ->
        {nil, []}

      {:ok, nil} when field == "valid_to" ->
        {nil, []}

      {:ok, raw} when is_binary(raw) ->
        case Date.from_iso8601(raw) do
          {:ok, date} -> {date, []}
          {:error, _} -> {nil, [error(index, field, "#{field} must be an ISO date, got #{inspect(raw)}")]}
        end

      {:ok, raw} ->
        {nil, [error(index, field, "#{field} must be an ISO date, got #{inspect(raw)}")]}
    end
  end

  defp error(index, field, message), do: {:error, %{index: index, field: field, error: message}}
  defp warning(index, field, message), do: {:warning, %{index: index, field: field, error: message}}
end
