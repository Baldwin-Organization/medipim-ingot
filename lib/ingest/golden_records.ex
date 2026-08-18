# lib/ingest/golden_records.ex — project the re-derived log into golden records (gr-8r6).
#
# Stage 5 of the legacy-medipim ingest, the PRIMARY deliverable, after envelope_loader (gr-n8i),
# claim_mapping (gr-beo) and rederive (gr-chq). Per the design
# (docs/plans/2026-06-05-legacy-history-ingest-design.md, "Ingest pipeline" step 5): fold the
# re-derived log into customer-facing golden records — products ▸ variants ▸ {codes, resolved
# attributes (survivorship), CNK canonical+alias, categories, media} — plus the pass-through
# go-forward `log` so the change feed / lookups stay available downstream.
#
# WHY Catalog.project, NOT History.now (this is the load-bearing choice for this bead) ─────────
# The ingest log carries INTEGER Unix-epoch timestamps (recorded_at / valid_from are ints like
# 1535726805 — see envelope_loader.ex), because the legacy medipim dump is epoch-stamped and the
# ingest does not (yet) convert them. The engine's `History.*` projections AND `Api.get`/`Api.lookup`
# filter via `Date.compare/2`, which RAISES on integers. So we project DIRECTLY through
# `Catalog.project(members, live_claims, priority, overrides)`, which is Date-free: it folds the
# members + the CURRENT claim view, with recency decided by the integer `order` field (stamped by
# ClaimMapping/Rederivation), never by a timestamp comparison. Full temporal projection /
# time-travel over the ingest log is a KNOWN follow-up ("Temporal pass — follow-up, not v1"); it is
# deliberately out of scope here and we do NOT convert timestamps in the merged engine modules.
#
# SAFE engine entrypoints used (all Date-free): `Catalog.project` for the snapshot, and
# `PublicId.canonical(:cnk, key, log, priority)` to enrich each variant's CNK (canonical + aliases).
#
# PRIORITY — a PARAMETER, with a permissive default. The ingest has no canonical medipim
# source-priority table yet (out of scope), so the default `Priority.new(%{}, [])` leaves all
# sources unranked: they tie, and a genuine multi-source disagreement on a field surfaces honestly
# as `status: :needs_review` rather than silently picking a winner. Callers that DO have a ranking
# pass their own `%Priority{}`.
#
# MEDIA arrives via the media LANE (gr-kek): claim_mapping promotes the envelope's "media" and
# "descriptions" references to first-class records in their own lanes, tied to the product by
# :depicts/:describes edges — so `media` carries MED_* records and `descriptions` carries DSC_*
# records with traversal provenance. The legacy :media claim kind still resolves if present.
#
# SCOPE BOUNDARY: this bead produces ONLY the projection. It does NOT build the LegacyXref /
# legacy⟷SK map (gr-0c2), nor the demo script / synthetic fixtures (gr-bxf).

alias GoldenRecord.{Events, Substrate, Priority, Catalog, PublicId}

defmodule GoldenRecords do
  @moduledoc """
  Projects the re-derived ingest log into customer-facing golden records — products ▸ variants ▸
  {codes, survivorship-resolved attributes, CNK canonical+aliases, categories, media, substances,
  derived descriptions} — via the Date-free `Catalog.project` path (see the header for why, and
  for the media/description lanes promoted to first-class records by `ClaimMapping`).
  """

  # No steward overrides in the PoC — the ingest mints fresh keys and has no human-resolved
  # conflicts to replay, so both override maps are empty.
  @no_overrides %{attr: %{}, product: %{}}

  @doc """
  Project a `%{log, ledger}` re-derivation result (the output of `Rederivation.run/2` or
  `Rederivation.from_claims/2`) into golden records.

  Returns `%{records: [...], log: log}`, where `records` is a list of products, each
  `%{product: <legacy product label>, variants: [variant]}`, and each `variant` is

      %{
        key: "SK_n",                         # surrogate key
        codes: [canonicalized {scheme, value}, ...],
        cnk: %{canonical: {:cnk, "..."}, aliases: [...]} | nil,
        attributes: [{field, %{value, winner, status, candidates}}, ...],  # survivorship-resolved
        product: %{value, winner, status, candidates},
        categories: [{collection, value}, ...],
        media: [%{asset: "MED_n", role, source, uri}, ...],       # via :depicts edges
        substances: [%{key, codes, sources}, ...],                # via :contains edges
        descriptions: [%{key: "DSC_n", via, asserted_by, attributes}, ...]  # derived (gr-sw0)
      }

  `log` is passed through unchanged so downstream callers keep the engine's read layer
  (`Api.resolve_key/2`, `Api.changes_since/2`, `PublicId.collisions/2`).

  `priority` is the survivorship policy — a `%Priority{}` (tier ranking) OR a 2-arity injected rank
  fun `(dimension, source) -> rank` (e.g. medipim's context-aware, off-product-penalty scoring; see
  `Survivorship`). It defaults to the permissive `Priority.new(%{}, [])` so unranked-source conflicts
  surface as `:needs_review`. The toggle is thus reachable from the fold entry, not just `decide/3`.
  """
  def project(rederivation, priority \\ default_priority())

  def project(%{log: log, ledger: ledger}, priority)
      when is_struct(priority, Priority) or is_function(priority, 2) do
    # Fold state for CNK enrichment built ONCE — the ledger is already in hand, and the identity
    # claims fold once — instead of PublicId.canonical/4 refolding the whole log per variant.
    idclaims = PublicId.identity_claims(log)

    records =
      ledger.members
      |> Catalog.project(live_claims(log), priority, @no_overrides)
      |> Enum.map(fn %{product: product, variants: variants} ->
        %{product: product, variants: Enum.map(variants, &enrich(&1, ledger.members, idclaims, priority))}
      end)

    %{records: records, log: log}
  end

  @doc """
  Convenience entrypoint: re-derive `envelopes` at instant `at`, then project. Equivalent to
  `envelopes |> Rederivation.run(at) |> project(priority)`.
  """
  def from_envelopes(envelopes, at, priority \\ default_priority()) when is_list(envelopes) do
    envelopes |> Rederivation.run(at) |> project(priority)
  end

  @doc "The permissive default priority — every source unranked, so conflicts tie (see moduledoc)."
  def default_priority, do: Priority.new(%{}, [])

  # Attach the variant's customer-facing CNK (canonical + aliases) from the same fold state.
  defp enrich(variant, members, idclaims, priority) do
    Map.put(variant, :cnk, PublicId.canonical(:cnk, variant.key, members, idclaims, priority))
  end

  # The CURRENT ClaimAsserted view of the log — what Catalog.project folds over.
  defp live_claims(log) do
    log |> Enum.filter(&match?(%Events.ClaimAsserted{}, &1)) |> Substrate.current()
  end
end
