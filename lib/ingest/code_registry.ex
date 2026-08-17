# lib/ingest/code_registry.ex — the single source of medipim product-code knowledge (gr-6k4).
#
# Drives scheme handling from ONE table instead of patching country-by-country. Each medipim
# products_deltas field name maps to {engine_scheme_atom, classification}, where classification
# tells ClaimMapping how to use the code:
#
#   :identity     — a national/GTIN code that BRIDGES products in clustering (cnk, cip_acl7, gtin…).
#   :external_ref — identifies the product in ANOTHER system (cbId/ospId/…). Carried as an
#                   attribute, NEVER bridges (the over-merge/bridging-policy question is its own
#                   bead, gr-ose; default here is "do not bridge").
#   :attribute    — a non-identifying classification (hsCode customs, pbs reimbursement class).
#   :entity_id    — medipim's own id (productId) == the legacy entity; not a code claim at all.
#
# The roster was extracted from medipimv2's ProductIdentifierInterface value objects +
# ProductMetaFieldBuilder / ProductCodeFactory (see docs/plans/2026-06-08-product-code-registry-design.md).
# Adding a market later is a data change here, not a code change.
#
# The engine atom — NOT the medipim field name — is what Codes canonicalizes and what clustering
# bridges on. The GTIN family (ean/gtin/eanGtin*/upc*/…) all collapse to :gtin; national codes
# keep their own atom. The only field-name ≠ canonical-code mismatch is cipOrAcl7 -> :cip_acl7.

defmodule CodeRegistry do
  # medipim field name => {engine scheme atom, classification}.
  @registry %{
    # ── identity — national codes (each its own scheme atom) ──────────────────
    "cnk" => {:cnk, :identity},
    "cipOrAcl7" => {:cip_acl7, :identity},
    "acl13" => {:acl13, :identity},
    "cip13" => {:cip13, :identity},
    "pzn" => {:pzn, :identity},
    "pznAustria" => {:pzn_austria, :identity},
    "sukl" => {:sukl, :identity},
    "pdk" => {:pdk, :identity},
    "cn" => {:cn, :identity},
    "cefip" => {:cefip, :identity},
    "nationalCode" => {:national_code, :identity},
    "ndc" => {:ndc, :identity},
    "hri" => {:hri, :identity},
    "pin" => {:pin, :identity},
    "fred" => {:fred, :identity},
    "zcode" => {:zcode, :identity},
    "lppr" => {:lppr, :identity},

    # ── identity — GTIN family (all fold to :gtin; Codes canonicalizes to GTIN-14) ─
    "ean" => {:gtin, :identity},
    "gtin" => {:gtin, :identity},
    "eanGtin8" => {:gtin, :identity},
    "eanGtin12" => {:gtin, :identity},
    "eanGtin13" => {:gtin, :identity},
    "eanGtin14" => {:gtin, :identity},
    "undefinedEanGtinCode" => {:gtin, :identity},
    "usaGtinCode" => {:gtin, :identity},
    "upc10" => {:gtin, :identity},
    "upc11" => {:gtin, :identity},
    "upc12" => {:gtin, :identity},

    # ── external-ref — identify the product in another system, do NOT bridge ──────
    "cbId" => {:cb_id, :external_ref},
    "ospId" => {:osp_id, :external_ref},
    "offisanteId" => {:offisante_id, :external_ref},
    "cisCode" => {:cis_code, :external_ref},
    "publicPageIdentifier" => {:public_page_identifier, :external_ref},

    # ── the AU market (gr-sx7.1; evidence: analysis/au-20260814/au-quality-report.md §1) ─
    # artgId is an IDENTITY code that must NEVER BRIDGE: one ARTG registration covers many
    # pack sizes/variants (3,807 of 9,944 live ARTG numbers sit on >1 entity, worst 90 — the
    # AU export itself refutes the report's national-grade recommendation). Same treatment as
    # restricted in-store GTINs: folded into the code-set, marked shared by ClaimMapping
    # (@non_bridging_schemes), bridge_grade :none.
    "artgId" => {:artg_id, :identity},
    # AMT concept ids (SNOMED CT-AU): identify clinical concepts in another system, not this
    # trade item — carried, never bridge.
    "snomedCtpp" => {:snomed_ctpp, :external_ref},
    "snomedTpp" => {:snomed_tpp, :external_ref},
    "snomedMpp" => {:snomed_mpp, :external_ref},
    "snomedTp" => {:snomed_tp, :external_ref},
    "snomedMp" => {:snomed_mp, :external_ref},
    "snomedTpuu" => {:snomed_tpuu, :external_ref},
    "snomedMpuu" => {:snomed_mpuu, :external_ref},
    # a supplier's own reference — the engine already has the non-bridging :supplier_ref notion.
    "supplierReference" => {:supplier_ref, :external_ref},

    # ── identity — the books vertical (gr-vgb: the genericity gate) ──────────────
    # ISBN rows are DATA, exactly like adding a pharma market. isbn13 is the canonical scheme
    # (an ISBN-13 is a Bookland EAN-13); the 10 → 13 VALUE conversion is the adapter's job
    # (Isbn.to_isbn13/1 — the engine's normalizer vocabulary has no mod-11 transform), so a raw
    # "isbn10:…" on the wire keeps its own scheme atom rather than being silently mislabeled.
    "isbn13" => {:isbn13, :identity},
    "isbn10" => {:isbn10, :identity},

    # ── entity-id — medipim's own id == the legacy entity, not a code claim ───────
    "productId" => {:product_id, :entity_id},

    # ── attribute / classification — non-identifying ──────────────────────────────
    "hsCode" => {:hs_code, :attribute},
    "pbs" => {:pbs, :attribute}
  }

  # Unknown field => a conservative default: keep the raw field name as the scheme (NEVER
  # String.to_atom/1 on unvalidated input — the loader does not whitelist schemes, so that would
  # be an atom-table leak), classified as a non-bridging :attribute.
  @default_classification :attribute

  @doc "The full medipim field => {scheme, classification} registry."
  def table, do: @registry

  @doc """
  Engine scheme for a medipim field. Known fields map to their engine atom (GTIN family => :gtin);
  an unknown field stays its raw string (Codes.canonicalize passes unknown schemes through).
  """
  def scheme(field) do
    case Map.get(@registry, field) do
      {scheme, _class} -> scheme
      nil -> field
    end
  end

  # Engine-native scheme names ("cnk", "gtin", "cip_acl7", …) => their atoms — the vocabulary the
  # Product API's live-claims contract speaks. Derived from the registry's VALUE side (plus the
  # non-bridging schemes ClaimMapping knows), so it cannot drift. Unknown names stay strings —
  # conservative pass-through, never String.to_atom/1 on input.
  # :ean / :upc are accepted spellings of the GTIN family (Codes.canonicalize folds them to
  # :gtin); :mpn / :supplier_ref are the non-bridging schemes ClaimMapping knows. The lane
  # schemes (gr-dig) identify NON-PRODUCT entities — substances (:cas/:unii/:substance_id),
  # descriptions (:text_id), media (:asset_id/:leaflet_id) — plus :uuid, the engine-minted shared
  # scheme;
  # Lanes.lane_of_scheme/1 routes each to its entity lane.
  @engine_schemes %{
                    "mpn" => :mpn,
                    "supplier_ref" => :supplier_ref,
                    "ean" => :ean,
                    "upc" => :upc,
                    "cas" => :cas,
                    "unii" => :unii,
                    "substance_id" => :substance_id,
                    "text_id" => :text_id,
                    "asset_id" => :asset_id,
                    "leaflet_id" => :leaflet_id,
                    "uuid" => :uuid
                  }
                  |> Map.merge(
                    for {_field, {scheme, _class}} <- @registry, into: %{} do
                      {Atom.to_string(scheme), scheme}
                    end
                  )

  @doc "Engine scheme atom for an engine-native scheme NAME (\"cnk\" => :cnk); unknown names pass through."
  def engine_scheme(name), do: Map.get(@engine_schemes, name, name)

  @doc "Classification for a medipim field (:identity | :external_ref | :attribute | :entity_id)."
  def classification(field) do
    case Map.get(@registry, field) do
      {_scheme, class} -> class
      nil -> @default_classification
    end
  end

  @doc "Does this medipim field carry a bridging identity code?"
  def identity_field?(field), do: classification(field) == :identity

  @doc "The set of medipim field names classified as :identity (for the gen oracle in gr-lmt)."
  def identity_fields do
    for {field, {_scheme, :identity}} <- @registry, into: MapSet.new(), do: field
  end

  # ── bridge grade — an ORTHOGONAL axis over the engine SCHEME ATOM (gr-ose) ─────
  #
  # A SECOND, independent classification used ONLY by the over-merge guard: when a merge clusters
  # two legacy entities, is the shared bridge a NATIONAL identity code (trusted — the re-derivation
  # working as intended) or merely a reusable/reassignable BARCODE/GS1 code (suspect — medipim flags
  # such ambiguous matches as ProductCodeIdentityMatch / MED-11207)? This axis is keyed on the engine
  # scheme atom, NOT the medipim field, and is DELIBERATELY distinct from `classification/1`: acl13
  # and cip13 stay `:identity` there (they DO bridge in clustering) yet are barcode-grade here.
  @national_schemes MapSet.new([
                      :cnk,
                      :cip_acl7,
                      :cefip,
                      :pzn,
                      :pzn_austria,
                      :sukl,
                      :national_code,
                      :cn,
                      :pdk,
                      :ndc,
                      :hri,
                      :pin,
                      :lppr,
                      :fred,
                      :zcode,
                      # ISBNs are registration-agency-assigned once per title/format (ISO 2108),
                      # never reissued the way GS1 barcodes are — a trusted bridge (gr-vgb).
                      :isbn13,
                      :isbn10
                    ])

  @barcode_schemes MapSet.new([:gtin, :acl13, :cip13])

  @doc """
  Bridge grade of an ENGINE SCHEME ATOM — the over-merge guard's axis (gr-ose):

    * `:national` — a national identity code (cnk, cip_acl7, …); a merge sharing one is TRUSTED.
    * `:barcode`  — a reusable/reassignable GS1/barcode code (gtin, acl13, cip13); a merge bridged
                    SOLELY by one of these is SUSPECT.
    * `:none`     — anything else (external_ref / attribute / unknown) — not a bridge.
  """
  def bridge_grade(scheme) do
    cond do
      MapSet.member?(@national_schemes, scheme) -> :national
      MapSet.member?(@barcode_schemes, scheme) -> :barcode
      true -> :none
    end
  end

  @doc "Is this engine scheme atom a national identity code (trusted bridge)?"
  def national_grade?(scheme), do: bridge_grade(scheme) == :national

  @doc "Is this engine scheme atom a GS1/barcode code (suspect bridge)?"
  def barcode_grade?(scheme), do: bridge_grade(scheme) == :barcode
end
