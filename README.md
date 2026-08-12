# Product master-data: golden records from contradicting sources

A runnable design exploration for a product master-data model where products are identified by
many codes (EAN/GTIN, CNK, MPN, supplier refs), codes come from **multiple sources that
contradict each other**, and a **priority list** resolves the conflicts into a clean, unique,
**event-sourced** golden record.

The repository now contains both a dependency-free pure engine and a Postgres-backed API shaped
for a production pilot. It is still a POC, not a live service. The engine remains pure data +
functions (no GenServers); the API stores an append-only JSON event log and disposable indexed
read models.

## Layout

A dependency-free Mix project: engine + ingest in `lib/`, suites in `test/`, runnable explainers
at the repo root.

| Path | What it is |
|------|------------|
| `lib/golden_record_core.ex` | The engine (library): contexts, aggregates, events, resolution, projection. |
| `lib/ingest/envelope_loader.ex` | Legacy-medipim ingest stage 1 — load + validate `HistoryEnvelope` JSON (contract C). |
| `lib/ingest/claim_mapping.ex` | Ingest stage 2 — fold listings, canonicalize/partition, build engine claims. |
| `lib/ingest/parity.ex` | The whole-product parity harness — engine fold vs the applier's snapshot, divergences classified. |
| `docs/HISTORY_ENVELOPE.md` | The contract-C spec the ingest consumes. |
| `api/` | The Product API for medipim — Plug+Bandit + Postgres service over the engine (`docs/API.md`). |
| `viz/` | The guided story demo + time machine (Astro + React; see `viz/README.md`). |
| `test/` | ExUnit suites (339 tests). Fixtures — incl. the real entity 422156 — under `test/ingest/fixtures/`. |
| `golden_record_ddd.exs` | DDD + event-sourced walkthrough — event log, golden as a fold, time travel, conflicts, verdicts. |
| `golden_record_stress.exs` | Stress tests — multiple products + JSON, code collision → shared, 3-way contradictions, media re-homing. |
| `golden_record_api.exs` | Customer-facing layer — ATC collections, CNK public identity, the read API. |
| `golden_record.exs` | The original pre-DDD procedural version (standalone; kept for comparison). |
| `parity_harness.exs` | Runs the parity harness over a cohort directory (`test/ingest/fixtures/README.md` has the export contract). |

```sh
mix test                            # the engine suites
mix test --cover                    # with coverage
mix run golden_record_ddd.exs       # the guided tour
mix run golden_record_stress.exs    # the hard cases
mix run golden_record_api.exs       # collections, CNK, the read API
elixir golden_record.exs            # the standalone pre-DDD version

mix run parity_harness.exs test/ingest/fixtures   # whole-product parity over a cohort
```

## Try the API story

`api/README.md` walks through three executable examples:

1. **Clean merge:** two listings share strong identity evidence and become one stable identity.
2. **Contradiction:** equally trusted sources disagree, so Ingot returns no arbitrary winner and
   opens an evidence-bound review case.
3. **Late correction:** a supplier corrects February data in July; `effective_at` chooses the
   real-world date while `known_at` reproduces what Ingot knew before or after July.

The exact request bodies are also in `contract/api_examples.json`, and
`api/test/contract_test.exs` executes them against the real routes.

## Git hooks

A version-controlled `pre-push` hook (`.githooks/pre-push`) refuses to push unformatted code: it
runs `mix format --check-formatted` in both Mix projects (repo root and `api/`), exactly as CI
does. Enable it once per clone:

```sh
git config core.hooksPath .githooks
```

## The model in one paragraph

Everything is a **graph of code-identified nodes** (products, variants, media, categories)
joined by **edge-claims** (grouping, classification, hierarchy, media links). Every node and
edge is an immutable, versioned, **bitemporal** claim from some source. Resolution is a pure
function `f(claims, priority) -> golden`, run in two steps: **cluster** the raw evidence, then
**reconcile** clusters to *stable surrogate keys* via an identity cross-reference ledger (the
*xref*) — matched against the evidence, **never** against the golden output. The golden catalog,
the ledger, and the stewardship queue are all just **folds over the log**, so you can replay to
any past point and trace any key's full lineage.

### Key decisions captured here

- **Identity = `(source, scheme, code)`** at the source layer; uniqueness is enforced only at the
  golden layer, where `(scheme, code)` owns one product *unless explicitly marked shared*.
- **Per-dimension priority**: each field/scheme has its own ranked list of source tiers; a tie at
  the top tier is **undecidable → steward review**.
- **Stable surrogate keys** anchored in the xref so identity survives updates; `mint / merge /
  split` are recorded events with lineage. Merges of established keys are **gated** for review,
  never automatic.
- **History is bitemporal**: `valid_from` (true in the world) vs `recorded_at` (when we learned
  it); both are queryable.
- **Normalization before contradiction**: GTIN-family codes (EAN-8/UPC-12/EAN-13/GTIN-14)
  canonicalize to a 14-digit GTIN so equivalent representations stop looking like conflicts.
- **Public identity (CNK)** is *not* the internal key: it's an identity-grade, strictly-unique,
  redirect-on-reassign **alias** of the surrogate key. The API resolves any CNK → surrogate key →
  canonical CNK, so churn underneath stays invisible to customers.
- **Collections (e.g. ATC)** are nodes-with-codes, and membership/hierarchy are **edge-claims** —
  so a collection is the projection of its live edges (union, per-member contradiction, full
  history), and memberships **re-home** through splits/merges exactly like media.
- **The read API** (`Api`/`PublicId`) exposes `resolve_key`/`lookup` (by code, the robust pattern),
  `identity_status` (active / merged→survivor / split→parts) for stale-key redirects, `changes_since`
  (a cursored change feed of identity events), and a CNK uniqueness invariant check.

### Known limits (by design, not bugs)

- Distinguishing "same product, two codes" from "two different products" needs evidence beyond the
  disputed code; absent it, the system raises a **merge-candidate for a steward** rather than
  guessing.
- Aggressive/fuzzy equivalence is **proposed, not auto-applied** — over-normalization (false
  merges) is worse than a visible conflict.
