# lib/contract/canonical_claims.ex — canonical claims (the wire shape) → engine claims (gr-3jd).
#
# The GENERIC half of the ingest split: source-agnostic, contract-driven translation from
# canonical claim maps (docs/CLAIMS_CONTRACT.md — the same shape `POST /v1/claims` accepts) into
# the engine's `%Events.ClaimAsserted{}` structs. Every path into the engine meets here: the
# medipim reference adapter (lib/ingest/claim_mapping.ex) derives these maps from legacy
# envelopes; the Product API's live path (`Api.Writes.claims/1`, gr-ajc) takes them off the wire.
#
# Validation at the seam — DOCUMENTED CHOICE (gr-3jd): the executable contract
# (`ClaimsValidator`) runs in `to_engine/2`, the live-wire entrypoint, and is SKIPPED by
# `to_engine!/2`, the trusted/backfill entrypoint. A backfill batch deliberately exceeds the
# live wire on two axes the validator (correctly, per the spec) rejects:
#
#   * `member_of` claims — produced by the medipim adapter but not yet on the wire contract
#     (open question 1 in docs/CLAIMS_CONTRACT.md; shape below follows its candidate).
#   * temporal fields as unix-second integers (contract C's clock, docs/HISTORY_ENVELOPE.md)
#     instead of ISO dates — the backfill carries the historical `recorded_at` the live
#     contract reserves for the server.

alias GoldenRecord.{Lanes, Relations, Substrate}

defmodule CanonicalClaims do
  @moduledoc """
  Generic canonical-claims → engine-claims translation (`docs/CLAIMS_CONTRACT.md`).

  Input is a decoded claims batch: a list of string-keyed claim maps in the wire shape. Codes
  are `"scheme:value"` strings (`parse_code/1` / `code_string/1` are the two directions);
  unknown schemes pass through as strings — conservative, never an atom leak.

  Two entrypoints, differing only in whether the executable contract runs at the seam:

    * `to_engine/2` — VALIDATES the batch with `ClaimsValidator` first; `{:ok, claims}` or
      `{:error, errors}` (whole batch, nothing partial). The live-wire path.
    * `to_engine!/2` — no validation, raises on a malformed claim. The trusted path for
      backfill batches, which deliberately exceed the live wire (`member_of` claims and
      unix-second temporal fields — see the header comment).

  Temporal fields: each claim carries its own `"recorded_at"` (backfill), unless the caller
  passes `recorded_at:` (the live path's server-side clock, which clients cannot supply).
  `"valid_from"` is optional — an ISO 8601 date string (live wire) or a unix-second integer
  (backfill flavor) — and defaults to the claim's `recorded_at`.
  """

  @doc """
  Validate the batch against the contract, then translate. `{:ok, [%Events.ClaimAsserted{}]}`
  in batch order, or `{:error, errors}` with `ClaimsValidator`'s per-index findings.
  """
  def to_engine(claims, opts \\ []) do
    case ClaimsValidator.validate(claims, opts) do
      {:ok, _warnings} -> {:ok, to_engine!(claims, opts)}
      {:error, errors} -> {:error, errors}
    end
  end

  @doc """
  Translate WITHOUT validating — the trusted/backfill entrypoint (see the module doc for why a
  backfill batch cannot pass the live-wire validator). Raises on a malformed claim.
  """
  def to_engine!(claims, opts \\ []) when is_list(claims) do
    recorded_at = Keyword.get(opts, :recorded_at)
    registry = Keyword.get(opts, :scheme_registry)
    Enum.map(claims, &build(&1, recorded_at, registry))
  end

  # ── one claim map → one engine claim ────────────────────────────────────────
  defp build(%{"kind" => "identity", "source" => s, "ref" => ref, "codes" => codes} = m, at, registry) do
    data = %{ref: ref, codes: Enum.map(codes, &code!(&1, registry))} |> put_entity(m)
    asserted(s, :identity, data, m, at)
  end

  # An edge claim (gr-xde): both endpoints are "scheme:value" codes; the relation must be one
  # the registry declares (Relations.parse/1 — a whitelist, never String.to_atom on input).
  defp build(
         %{"kind" => "edge", "source" => s, "from" => f, "relation" => r, "to" => t} = m,
         at,
         registry
       ) do
    {:ok, relation} = Relations.parse(r, registry)
    data = %{from: code!(f, registry), relation: relation, to: code!(t, registry)}
    asserted(s, :edge, data, m, at)
  end

  defp build(
         %{"kind" => "attribute", "source" => s, "code" => c, "field" => f, "value" => v} = m,
         at,
         registry
       ) do
    data = %{code: code!(c, registry), field: f, value: v}
    asserted(s, :attribute, data, m, at)
  end

  defp build(
         %{"kind" => "media", "source" => s, "asset" => a, "target" => t, "uri" => uri} = m,
         at,
         registry
       ) do
    role = if m["role"] == "primary", do: :primary, else: :secondary
    data = %{asset: {:dam, a}, target: code!(t, registry), role: role, uri: uri}
    asserted(s, :media, data, m, at)
  end

  defp build(%{"kind" => "grouping", "source" => s, "code" => c, "product" => p} = m, at, registry) do
    asserted(s, :grouping, %{code: code!(c, registry), product: p}, m, at)
  end

  # member_of is NOT on the live wire yet (open question 1 in docs/CLAIMS_CONTRACT.md); this is
  # its candidate shape: `code` is a member of `collection`/`member` (e.g. brands/211). The
  # collection name is NOT scheme-folded — it is a collection namespace, not a code scheme.
  defp build(
         %{"kind" => "member_of", "source" => s, "code" => c, "collection" => coll, "member" => member} = m,
         at,
         registry
       ) do
    data = %{member_code: code!(c, registry), collection: {coll, member}}
    asserted(s, :member_of, data, m, at)
  end

  # ── codes: the two directions of "scheme:value" ─────────────────────────────
  @doc ~s(Parse one "scheme:value" string into an engine {scheme, value} code tuple.)
  def parse_code(raw), do: parse_code(raw, nil)

  def parse_code(raw, registry) when is_binary(raw) do
    case String.split(raw, ":", parts: 2) do
      [scheme, value] when scheme != "" and value != "" ->
        canonical =
          case registry do
            %SchemeRegistry{} -> SchemeRegistry.canonical_name(registry, scheme) || scheme
            nil -> scheme
          end

        {:ok, {CodeRegistry.engine_scheme(canonical), value}}

      _ ->
        {:error, ~s(code must be "scheme:value", got #{inspect(raw)})}
    end
  end

  def parse_code(raw, _registry),
    do: {:error, ~s(code must be a "scheme:value" string, got #{inspect(raw)})}

  @doc ~s"""
  Format an engine `{scheme, value}` code tuple as a `"scheme:value"` wire string — the inverse
  of `parse_code/1` (engine-native scheme atoms round-trip via `CodeRegistry.engine_scheme/1`;
  unknown string schemes pass through, provided they contain no colon).
  """
  def code_string({scheme, value}), do: "#{scheme}:#{value}"

  # ── temporal fields ─────────────────────────────────────────────────────────
  # Caller-supplied recorded_at (live path: the server's clock) wins; otherwise the claim must
  # carry its own (backfill path: contract C's unix seconds).
  defp recorded_at(m, nil), do: Map.fetch!(m, "recorded_at")
  defp recorded_at(_m, at), do: at

  defp valid_from(%{"valid_from" => raw}, _at) when is_binary(raw), do: Date.from_iso8601!(raw)
  defp valid_from(%{"valid_from" => vf}, _at) when not is_nil(vf), do: vf
  defp valid_from(_m, %DateTime{} = at), do: DateTime.to_date(at)
  defp valid_from(m, at), do: recorded_at(m, at)

  defp valid_to(%{"valid_to" => raw}) when is_binary(raw), do: Date.from_iso8601!(raw)
  # The backfill flavor carries contract-C unix seconds, the same as valid_from above.
  defp valid_to(%{"valid_to" => vt}) when not is_nil(vt), do: vt
  defp valid_to(_m), do: nil

  defp asserted(source, kind, data, map, at) do
    source
    |> Substrate.claim(kind, data, valid_from(map, at), recorded_at(map, at))
    |> Map.put(:valid_to, valid_to(map))
  end

  defp code!(raw, registry) do
    {:ok, code} = parse_code(raw, registry)
    code
  end

  # Optional "entity" on identity claims (gr-2a8): the lane, needed only when every code is
  # lane-neutral (engine-minted uuid). Whitelisted via Lanes.parse/1 — never an atom leak.
  defp put_entity(data, %{"entity" => name}) do
    {:ok, lane} = Lanes.parse(name)
    Map.put(data, :entity, lane)
  end

  defp put_entity(data, _m), do: data
end
