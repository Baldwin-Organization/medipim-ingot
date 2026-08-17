# Ingot quality sweep — medipim AU export (2026-08-14)

**Input:** `prod-lu-20260814.csv` (713 MB — filename says LU, content is unmistakably AU: GS1-Australia 93x EAN prefixes, English names, PBS/ARTG fields).
**Profile:** 4,188,644 delta rows · 126,999 entities · Feb 2023 → Aug 2026.
**Method:** streaming pre-flight over all rows; then a 500-entity cohort (the 350 with the most raw identity churn + 150 random baseline) decoded with the contract-C oracle (`gen.exs`) and folded through the real pipeline (`Temporal.run` → `LegacyXref` → `golden_as_of`). Zero decode or fold failures.

---

## 1. Registry pre-flight — AU fields unknown to `CodeRegistry`

These fields currently degrade to non-bridging attributes. Recommended classifications (a data change in `code_registry.ex`, per its design):

| field | events | recommendation |
|---|---|---|
| `artgId` | 73,570 | **`:identity`, national grade** — the ARTG number; it already produces review ties today because it's treated as a plain attribute |
| `snomedTpp` / `snomedTp` / `snomedMp` / `snomedMpuu` / `snomedTpuu` | ~497,000 | `:external_ref` — AMT concept ids; identify clinical concepts, not this trade item; must not bridge |
| `supplierReference` | 83,360 | non-bridging (engine already has the `:supplier_ref` notion) |
| `scheduleCode`, `gs1Category`, `atcCategory`, `atc`, `artgCategory`, `gstApplicable`, `intendedSite`, `routeOfAdministration`, … | — | `:attribute` (the default already does the right thing) |
| `replacement`, `deleted`, `officialDeletionAt` | 2,750 / 4,868 / 7,511 | lifecycle signals — see §3; worth carrying as explicit attributes rather than dropping |
| `leaflets` | 69,347 | a media-like collection unknown to the decoder's media list — currently decoded as attribute churn; add to the media set |

Good news: the oracle already strips AU's `<scheme>_`-prefixed code values (`eanGtin13_00511319…` decodes to the bare code), so codes canonicalize correctly as-is.

## 2. Identity health — clean

On the cohort (which deliberately over-samples the churniest entities):

- **0 entities** fold to more than one identity; **0 held merges**; **0 splits**.
- The raw "churn" (118,243 entities with >1 distinct identity field=value pair) is almost entirely the `ean → eanGtin13 → eanGtin14` **scheme migrations**, which canonicalization collapses to no-ops — same lesson as the BE fixture.
- 470/500 resolve `:stable` under `LegacyXref`; the entity id → golden key mapping is trivially preservable for AU.

## 3. The 30 "unknown" entities = the replacement lifecycle

All 30 non-resolving entities end with **zero codes** — and they follow one pattern: `status := replaced`, `replacement := MD…` (a new-system id), then the EAN removed and GTIN fields nulled. Identity intentionally dies at end-of-life. 31 cohort entities show such retractions. Implication for ingest: `replacement` should be decoded (probably as an external_ref edge to the successor) so the golden record can answer "this product was replaced by X" instead of just going dark.

## 4. Attribute contradictions — small, and half of it is unit noise

24/500 entities carry `needs_review` ties under the permissive (unranked) priority:

- Fields: `name:en` (22) · `weight`/`width`/`depth`/`length` (12–17) · `artgId` (5) · `status` (5) · `snomedMp`/`Mpp` (2)
- Tie participants: org **1** (24×), org **220** (15×), org **1033** (9×)
- **The dimension ties are largely false conflicts**: org 1 writes `weight: 35` (bare number) while org 220 writes `0.035_kg` / `10.2_cm` strings — same fact, different serialization. A unit-normalization step in the AU decode (or survivorship policy) removes most of this class.
- The `name:en` ties are real editorial disagreements — steward or ranking material (e.g. rank org 1 above 220 for names, one line in an AU policy module, resolves 22 entities at once).

## 5. Cross-entity code collisions — the real migration checklist

A full-export scan of *live* code ownership (adds minus removes) found:

- **587 canonical GTINs claimed by more than one entity** — 371 pairs, 216 triples (of 129,368 distinct codes; ≈0.45%).
- A visible pattern in the worst cases: **pack-level GTIN-14s** (indicator digit 1/2) claimed by one entity colliding with related entities — e.g. `19350299004134` live on entities 118705, 127851 and 2903. Plus plain duplicate listings of the same product.
- These are precisely the cases the engine's `shared`-code marking and barcode-grade merge gating exist for: folded together, each collision either legitimately merges duplicates, or must be marked shared / sent to review. **This list (au_collisions.json) is the pre-migration review queue.**
- Caveat: `set NULL` events couldn't be attributed to a specific code in this streaming scan, so 587 is an upper bound; the engine fold would give the exact number.

**Engine verdicts (gr-sx7.2, run 2026-08-17 — `verify_collisions.exs` → `au_collision_verdicts.json`).** Each collision group folded jointly through gen.exs → ClaimMapping → Rederivation → LegacyXref:

| verdict | codes | meaning |
|---|---|---|
| `single_owner` | 358 | history dissolves the collision — exactly one final key holds the code (incl. the report's worst pack-GTIN example `19350299004134`) |
| `not_live` | 120 | the code survives on **no** key — the streaming scan's upper-bound artifact (`set NULL` attribution) |
| `merged_suspect` | 106 | genuine duplicate listings the engine merges, every one bridged by barcode only → flagged `:suspect` (gr-ose) — **this is the actual review queue** |
| `shared` | 3 | carried on >1 key without fusing |
| `merged` (trusted) | 0 | expected: AU has no national-grade codes to trust a bridge on |

So the real pre-migration review queue is **106 suspect merges + 3 shared codes**, not 587; 183 of the flagged 587 involve an end-of-life (replaced) entity on at least one side (`dead_entities` in the verdicts file).

## 6. Verdict

The AU catalog is young and identity-clean — no BE-style held merges, migrations are cosmetic, and id continuity is a non-issue. The actionable quality work, in order of value:

1. Add `artgId` (identity/national) + `snomed*` (external_ref) + `leaflets` (media) to the registry — data change.
2. Review the 587-code collision list before any migration (mostly pack-GTIN sharing + duplicates).
3. Normalize units in AU dimension fields to kill the false-conflict class.
4. Decode `replacement` so end-of-life products point at their successor.
5. Rank orgs per field (names: org 1 vs 220) to auto-resolve the editorial ties.

**Artifacts:** `au_quality.json` (per-entity metrics, worst-20), `au_collisions.json` (all 587 collisions with entity lists), decoded envelopes in `au_env/` — all in the session scratchpad.
