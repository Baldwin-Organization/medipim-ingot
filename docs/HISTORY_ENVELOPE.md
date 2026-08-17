# `HistoryEnvelope` — contract C

The boundary between legacy **medipim** (source) and this engine (system of record).
One envelope = **one legacy entity**. The ingest accepts a **list** of envelopes and clusters
across all of them — that is how cross-entity merges surface.

The envelope is **decoded but unresolved**:

- **Decoded** — medipim's storage quirks are already gone: opcodes → ops, the `field[:locale][:org]`
  key grammar is parsed, `eanGtin13_`/`eanGtin14_` value prefixes are stripped, fields are
  classified into a `kind`, and touch-only deltas are dropped.
- **Unresolved** — no folding into code-sets, **no survivorship**, no clustering, no identity.
  Events are a flat, time-ordered, granular list faithful to the delta log. The legacy `entity`
  rides along as metadata only; it is **never** a clustering input downstream.

Source of the decode rules: `medipimv2` —
`src/Baldpim/Domain/Common/EventSourcing/Event.php` (opcodes),
`src/Baldpim/Domain/Product/WriteModel/ProductDeltaApplier.php` (key grammar),
`src/Baldpim/Domain/Product/ProductCode/WriteModel/Gtin/GtinCodeHelper.php` (value prefixes),
`src/Baldpim/Domain/Product/Meta/ProductMetaFieldBuilder.php` (field registry + source scores).

---

## Envelope shape

```jsonc
{
  "schema_version": "1",
  "source_system": "medipim-be",   // platform region: medipim-be
  "legacy_entity": 422156,          // products_deltas.entity — METADATA ONLY, never clusters
  "last_touched_at": 1749646919,    // max updatedAt over ALL deltas incl. dropped ones (trigger signal)
  "dropped_meta_count": 540,        // how many touch-only deltas were filtered out
  "events": [ /* flat, time-ordered Event list — see below */ ]
}
```

| field                | type     | notes |
|----------------------|----------|-------|
| `schema_version`     | string   | contract version; loader validates. `"1"`. |
| `source_system`      | string   | which medipim platform/region emitted this. `"medipim-be"`. |
| `legacy_entity`      | integer  | `products_deltas.entity`. Carried for the `LegacyXref` baseline; **not** a clustering code. |
| `last_touched_at`    | integer  | unix seconds. Max `updatedAt` across every delta, **including dropped touch-only ones**. The "your product changed, go look" signal for manufacturers/pharmacists. |
| `dropped_meta_count` | integer  | count of touch-only deltas dropped during decode. Audit only. |
| `events`             | array    | time-ordered ascending by `recorded_at`. |

---

## Event shape

```jsonc
{
  "recorded_at": 1535726805,   // products_deltas.created_at (unix s) — when medipim recorded it
  "valid_from":  1535726805,   // optional; defaults to recorded_at. For bitemporal back-dating.
  "by":   2,                   // products_deltas.created_by (user id)
  "tag":  "import_871",        // products_deltas.tag — provenance label
  "source": "1034",            // organization id from the key suffix = the SOURCE. null if unsourced.
  "op":   "set",               // set | add | remove | delete  (see opcode map)
  "kind": "identity",          // identity | attribute | edge | media  (see taxonomy)

  // payload depends on kind:
  "scheme": "cnk",             // identity: code scheme
  "code":   "3612173"          // identity: the (prefix-stripped) code value
  // attribute: "field","locale"?,"value"
  // edge:      "collection","value"
  // media:     "asset"
}
```

Common fields:

| field         | type            | notes |
|---------------|-----------------|-------|
| `recorded_at` | integer         | `created_at` of the delta. Sort key. |
| `valid_from`  | integer \| absent | bitemporal valid-time; omit when equal to `recorded_at`. |
| `by`          | integer \| null | `created_by` user id. |
| `tag`         | string \| null  | import/update tag. |
| `source`      | string \| null  | org id parsed from the key suffix. `null` when the field is unsourced (e.g. media, some edges). When a **sourced** field has no org suffix in the key, medipim defaults it to the **MEDIPIM** org id — the endpoint resolves that to the concrete id. |
| `op`          | string          | `set` \| `add` \| `remove` \| `delete`. |
| `kind`        | string          | `identity` \| `attribute` \| `edge` \| `media`. |

---

## Opcode → `op`

medipim stores each event as a `[opcode, key, value]` triple
(`Event::TYPE_*`, `Event.php:12–23`).

| opcode | `op`     | meaning |
|--------|----------|---------|
| `1`    | `set`    | set a single-valued property |
| `2`    | `add`    | add a value to a collection |
| `3`    | `remove` | remove a value from a collection |
| `4`    | `delete` | drop a whole source entry for a scheme/field (e.g. `["4","eanGtin13",1034]` drops org 1034's `eanGtin13`) |
| `"update_sources"` (string) | — | **dropped.** A survivorship recompute, not a data change. This engine does its own resolution, so it carries no signal across the boundary. |

## Key grammar → `source` / `locale`

Key = `field[:locale][:organizationId]`, split on `:` (`ProductDeltaApplier.php:133–151`):

- `field` = first segment.
- a `locale` segment (e.g. `fr`, `de`, `nl`, `en`) appears on localized fields.
- a trailing **numeric** segment = the **organization id = `source`**.
- a sourced field with no numeric segment → defaults to the MEDIPIM org id.

## Value prefix stripping (identity codes)

For `eanGtin8/12/13/14` (and `ean` variants), medipim stores values prefixed with `{field}_`
(`GtinCodeHelper::stripEanGtinFieldPrefix`, `GtinCodeHelper.php:62–75`).
The decode **strips** it: `"eanGtin13_3282770146004"` → `"3282770146004"`. The engine then runs
its own GTIN-14 canonicalization downstream (not here).

---

## `kind` taxonomy

| `kind`      | medipim fields                                   | engine target            | role in re-derivation |
|-------------|--------------------------------------------------|--------------------------|-----------------------|
| `identity`  | `cnk`, `ean`, `gtin`, `eanGtin8/12/13/14`        | identity claim codes     | **drives clustering** |
| `attribute` | `name`, `status`, price/tax, dims, …             | attribute claim (anchored to a code) | survivorship only |
| `edge`      | `publicCategories`, `brands`, `labos`, `internationalBrands`, `medipimCategories`, `organizations` | `member_of` claim | re-homes; not identity |
| `media`     | `media`, `descriptions`, `leaflets` (AU)         | media claim              | noise for identity |
| `meta`      | `updatedAt`, `updatedBy`, `createdAt`, `createdBy`, `legacyId` | **dropped at the boundary** | medipim-internal plumbing + touch signal; bumps `last_touched_at` |

> `organizations` is structural (which sources list the product) and is **derivable** from the
> `source` on the per-source events — downstream claim mapping may ignore it. `legacyId` is
> medipim's *own* previous-system id, not a product code, so it is dropped (not identity-grade).
> The authoritative field→kind mapping used to generate the 422156 fixture lives in
> `fixtures/gen_422156.exs`.

### identity payload
`scheme` (cnk \| ean \| gtin \| eanGtin8 \| eanGtin12 \| eanGtin13 \| eanGtin14) + `code` (stripped).

Two real edge cases from 422156:
- **delete (op 4)** carries the source in the **value**, not the key: `["4","eanGtin13",1034]`
  decodes to `{op:"delete", scheme:"eanGtin13", source:"1034"}` with no `code` — org 1034's whole
  `eanGtin13` entry is dropped.
- **set-null (clear):** `["1","eanGtin14:1034", null]` decodes to `{op:"set", scheme:"eanGtin14",
  source:"1034", code:null}` — the code is cleared. Fold treats `code:null` as removal.

### attribute payload
`field` (name, status, …) + optional `locale` + `value`.

### edge payload
`collection` (publicCategories, brands, labos) + `value` (the member id/code).

### media payload
`asset` (the asset id).

---

## Dropping touch-only deltas

A delta whose events reduce to nothing but `updatedAt`/`updatedBy` carries no
identity/attribute/edge/media signal and is the bulk of the volume, so the decode drops it.
Two things survive:

1. `updatedAt`/`updatedBy` riding **alongside** a real change become that event's `recorded_at`/`by`.
2. The product's true `last_touched_at` = **max `updatedAt` over all deltas (including dropped ones)**
   — preserved at the envelope level. `dropped_meta_count` records how many were filtered.

---

## What is deliberately NOT here

- **No survivorship.** medipim's per-source `sourceScores` (BE: APB ▸ SAM_V2 ▸ FEBELCO ▸ BCFI ▸
  PHARMA_BE ▸ FAGG ▸ MEDIPIM ▸ WIT_GELE_KRUIS ▸ MEDIPIM_AI; suppliers win at 0) decide *which
  value wins* — that is resolution, which this engine owns. The envelope keeps **every** source's
  events so the engine can re-resolve.
- **No folding.** Per-listing code-sets are computed downstream (`fold`), not here.
- **No clustering / identity.** `legacy_entity` is metadata; codes decide identity downstream.
