# Claim mapping: field-by-field

How one medipim `HistoryEnvelope` event becomes one engine claim. Companion to
`docs/HISTORY_ENVELOPE.md`, which defines the envelope itself.

## What this covers, and what it does not

**This spec is evidence-based, not exhaustive.** `ProductDelta` is defined in medipim
(`src/Baldpim/Domain/Product/WriteModel/`), which is not part of this repository. Every field
below was observed in the two real delta histories under `test/ingest/fixtures/` — medipim BE
entity 422156 and medipim FR entity 347025 — or is handled explicitly by
`lib/ingest/claim_mapping.ex`.

A field medipim can emit but neither fixture contains is **not** listed here. Unlisted fields are
not rejected: they fall through to the default attribute rule below. Extending the fixtures is the
way to extend this spec.

Regenerate the inventory with `test/ingest/fixtures/gen_422156.exs`.

## The four event kinds

| envelope kind | engine claim | slot | notes |
|---|---|---|---|
| `identity` | `identity` | `(source, ref)` | codes fold per listing; see *Identity ops* |
| `attribute` | `attribute` | `(source, code, field)` | `field` is `field[:locale]` — see *Dimensions* |
| `edge` | `edge` / `member_of` | `(source, from, relation, to)` | collections become `member_of` |
| `media` | `media` | `(source, asset, target)` | `add` / `remove` fold per listing |

## Dimensions

Survivorship resolves per **dimension**, and the dimension is `field[:locale]`, not `field`
(`ClaimMapping.field_dim/1`). A Dutch name and a French name are separate decisions that never
compete. Two sources disagreeing on `name:nl` is a contradiction; `name:nl` versus `name:fr` is not.

Only `name` and `seoName` are localised in the fixtures.

## What a claim is about

A claim is always about **one or more identifiers** — a cnk, an ean, a cn. It is never about a
product in the abstract. `Substrate.slot/1` addresses an attribute by `(source, code, field)`, and
an attribute reaches an identity only derivatively: `Survivorship.field_decisions/3` keeps the
attributes whose code is in that identity's member set. The link is recomputed on every fold,
which is why an attribute re-homes by itself through a merge or a split.

Two things follow, and together they replaced a heuristic with a rule.

### The identifiers are the ones the source held *when it spoke*

`ClaimMapping.codes_at/4` reads them out of the listing's periods. Not the final code set, not
another source's codes.

A source that stocked a product for years and then delisted keeps everything it said while it did
hold codes. Under the old final-state fold, an empty final set dropped the listing and erased that
source's entire history — sources `2` and `888` lost 36 events between them that way, including
`name`, `status`, `tax` and `publicPrice`, which other sources also assert. The field still
appeared in the golden record; only a disagreeing candidate had quietly gone missing.

### One claim per identifier, not one per listing

There is no "which code do we anchor to". An event becomes one claim per code its source held, so
an image carrying three EANs links to three products, and a claim survives a split by attaching
wherever its code went. `primary/1` no longer takes part in anchoring at all.

An **unsourced** event is scoped to the legacy entity, and the entity id is an identifier in its
own right — that is what `grouping` claims make first-class. It is therefore about every code the
entity carried at that instant, across listings. That is not borrowing another source's code: the
event never claimed to come from a source.

### An event that identifies nothing is refused

`build/1` returns `rejected:` alongside `claims:`. There is no point keeping a claim that can
never reach an identity, and no excuse for dropping it in silence either — the count belongs in
the backfill report and the fix belongs upstream.

| reason | events | who |
|---|---|---|
| `source_held_no_code` | 73 | `4996` and `5480` — they never assert a code anywhere in either fixture |
| `source_held_no_code` | 11 | sources that *do* identify the product, but spoke outside the window they held codes |

The first group is **settled, not outstanding**. `4996` reports the four sales-price aggregates and
`5480` reports packaging, and neither ever names a code for the product it is describing. Under the
rule at the top of this section there is nothing to attach their facts to, so they are refused —
loudly, in the ingest report, which is the part that was actually wrong before.

The second group is small and open: `gr-4iu` asks whether a source's codes may reach backwards
to facts it stated before identifying.

A third group no longer exists: three attributes stated **at the exact instant their source
delisted** used to fall into the empty period, because periods are half-open and the period
opening at an instant owns it. That is right for identity and wrong for a parting attribute —
the source is describing what it *had*, not the nothing it now has. Since `gr-gh0`, an attribute
at the exact delisting instant anchors to the codes the closing period held.

**Effect on the fixtures:** attribute claims went from 92 to 228 (anchoring at time-of-speech),
then to 237 (the delisting boundary, `gr-gh0`), and 8 of the 9 sources now reach claims rather
than 5. `4996` and `5480` still reach none, correctly — they identify nothing.

## Attribute fields observed

Counted from the raw envelopes. **Dropped** marks a field that still never reaches a claim,
because every source asserting it identifies nothing (`4996`, `5480`).

| field | n | value type(s) | localised | ops | dropped |
|---|---|---|---|---|---|
| `allowedSpecies` | 3 | list, string | — | add, set | — |
| `apbCategory` | 1 | string | — | set | — |
| `averageSalesPrice` | 31 | number | — | set | **yes** |
| `cbId` | 3 | null, string | — | delete, set | — |
| `claudeBernardCategoryId` | 1 | string | — | set | — |
| `conservation` | 6 | null, string | — | delete, set | — |
| `depth` | 2 | number | — | set | — |
| `expires` | 1 | boolean | — | set | — |
| `hsCode` | 1 | string | — | set | — |
| `length` | 2 | number | — | set | — |
| `limitedExport` | 1 | boolean | — | set | — |
| `manufacturerPrice` | 1 | number | — | set | — |
| `maximumDispenseQuantity` | 1 | number | — | set | — |
| `maximumSalesPrice` | 4 | number | — | set | **yes** |
| `medianSalesPrice` | 15 | number | — | set | **yes** |
| `minimumSalesPrice` | 20 | number | — | set | **yes** |
| `name` | 9 | null, string | yes | delete, set | — |
| `numericDistribution` | 3 | null, number | — | delete, set | — |
| `officialDeletionAt` | 3 | null, number | — | delete, set | — |
| `offisanteId` | 3 | null, string | — | set | — |
| `ospCategory` | 4 | null, string | — | delete, set | — |
| `ospId` | 3 | null, string | — | delete, set | — |
| `packageQuantity` | 2 | string | — | set | — |
| `packagingUnit` | 1 | string | — | set | **yes** |
| `pharmacistPrice` | 13 | null, number | — | delete, set | — |
| `popularity` | 3 | null, number | — | delete, set | — |
| `prescription` | 2 | boolean | — | set | — |
| `publicPageIdentifier` | 3 | string | — | set | — |
| `publicPrice` | 8 | null, number | — | delete, set | — |
| `rateOfReimbursement` | 3 | null, number | — | delete, set | — |
| `seoName` | 7 | string | yes | set | — |
| `status` | 17 | null, string | — | delete, set | — |
| `tax` | 11 | null, number | — | delete, set | — |
| `tradeInRefundValue` | 2 | null, number | — | set | — |
| `ttcPrice` | 3 | null, number | — | delete, set | — |
| `weight` | 3 | number, string | — | set | — |
| `width` | 2 | number | — | set | — |
| `yearlyAverageSales` | 2 | null, number | — | delete, set | **yes** |

## Identity schemes observed

| scheme | n | ops |
|---|---|---|
| `acl13` | 6 | delete, set |
| `cipOrAcl7` | 8 | delete, set |
| `cnk` | 3 | set |
| `ean` | 13 | add, delete, remove |
| `eanGtin13` | 14 | delete, set |
| `eanGtin14` | 6 | set |
| `gtin` | 5 | add, delete, remove |

## Other kinds observed

- edge / add: 15
- edge / remove: 4
- edge / set: 2
- media / add: 395
- media / remove: 373


## Identity ops

`ClaimMapping.apply_identity/2` folds an entity's identity events into a current code set per
listing:

| op | effect |
|---|---|
| `set` | replace every value for that scheme with this one |
| `set` with a null code | drop the scheme entirely |
| `add` | add one value to the scheme's set |
| `remove` | drop one value from the scheme's set |
| `delete` | drop the scheme entirely |

**Known gap.** This fold is a *current-value* fold: it answers "which codes does this listing carry
now". `remove` and `delete` therefore erase the fact that the code was ever attached, and the
interval it was attached for is lost. That matters because a barcode can move between products —
see `docs/ingot-walkthrough.html` slide 15 and issue `gr-blb`.

## Value handling

### Null and delete are different statements

Both currently produce `value: nil`, but they do not mean the same thing:

| envelope | means | should be |
|---|---|---|
| `op: delete` | the source withdraws its opinion | no claim for that slot |
| `op: set`, `value: null` | the source asserts the field is empty | a claim whose value is empty |

Most null-valued fields in the fixtures arrive via `delete`. Two do not — `offisanteId` and
`tradeInRefundValue` are `set` to null — so the distinction is real in the data, not theoretical.

`ClaimsValidator` rejects a null value (`scalar/3` allows string, number, boolean only), so the
backfill path and the live-wire path currently disagree about whether a null claim is legal.

### Cardinality

`allowedSpecies` arrives as both `"human"` and `["human"]`. A single-element list carries no more
information than its element, so it is unwrapped. Multi-element lists do not occur in the fixtures
and are left for the validator to reject rather than guessed at.

### Quantities — OPEN QUESTION, do not guess

`weight` arrives three ways from three sources:

```
source 1035   859
source 44     780
source 1386   "30_g"
```

`packageQuantity` arrives as both `"750"` and `"750 ml"`.

The string forms are clearly the same *kind* of thing as the numbers, but this repository cannot
prove they use the same **unit**. `859` and `30` are not reconcilable without knowing that the
integer form is grams — and nothing here says so.

So the mapping deliberately does **not** convert. Survivorship sees distinct values and returns
`needs_review`, which is the correct answer for "we do not know". Resolving this needs medipim to
state the unit of each numeric quantity field; until then, `needs_review` is honest and a silent
conversion would not be.

Note also that `hsCode` (`"340130"`), `offisanteId` (`"90902"`) and `ospId` (`"149806"`) are
digits-only strings that are **identifiers, not quantities**. Any future normalisation must be
driven by a per-field declaration, never by sniffing the value's shape.

## Default rule

A field not listed above becomes an `attribute` claim on dimension `field[:locale]`, with its
value passed through unchanged. That is deliberate: an unknown field is carried rather than
dropped, so a new medipim field shows up in the golden record without an engine change.
