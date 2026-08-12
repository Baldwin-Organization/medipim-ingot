# Storage foundation: Postgres with explicit two-clock facts

**Decision date:** 2026-07-10  
**Status:** accepted for the production pilot

## Decision

Keep Postgres as Ingot's only database.

Ingot will store:

- an append-only event log as the source of truth;
- explicit `recorded_at` timestamps for **when Ingot learned a fact**;
- explicit `valid_from` / `valid_to` intervals for **when the fact applies in the real world**;
- rebuildable, indexed Postgres tables for current and historical reads.

XTDB's time-travel SQL is clearer, but it does not win enough to justify a second database and its
operational model during the pilot.

## The two clocks, in plain language

Suppose a supplier tells us on July 1 that a product's March name was wrong.

- `effective_at = March 15` asks: **what was true on March 15?**
- `known_at = June 30` asks: **what answer could Ingot give before the correction arrived?**
- `known_at = July 2` asks the same real-world question using the corrected knowledge.

These clocks must stay independent. A late correction changes today's best answer about March, but
it must not rewrite what Ingot actually knew in June.

## Spike

Both databases ran the same six checks:

1. a future change does not appear too early;
2. it appears after its effective date;
3. a late correction is absent before Ingot receives it;
4. it appears after Ingot receives it;
5. a query made from the knowledge available before an identity merge still returns the old key;
6. the same effective date queried after the merge returns the merged key.

All six checks passed in both databases.

Postgres needs an explicit predicate:

```sql
WHERE recorded_at <= $known_at
  AND valid_from <= $effective_at
  AND valid_to > $effective_at
ORDER BY recorded_at DESC
LIMIT 1
```

XTDB expresses the same question directly:

```sql
FROM facts
  FOR SYSTEM_TIME AS OF $known_at
  FOR VALID_TIME AS OF $effective_at
```

That is a real XTDB advantage: the temporal query is shorter and harder to get subtly wrong.

## Measured comparison

There was no agreed pilot-volume limit when this spike started. To make the comparison concrete,
the provisional limit is **100,000 records with two revisions each**. The spike used twice that:
**200,000 records and 400,000 total versions**.

Measurements are one local Docker run on an Apple Silicon development machine. They are useful for
direction, not capacity planning.

| Check | Postgres 16 | XTDB latest |
| --- | ---: | ---: |
| Load 400,000 versions | 1.25 s | 1.91 s |
| Read a 200,000-record temporal snapshot | 0.13 s | 0.80 s |
| Read one record at a point in both clocks | 0.02 s | 0.05 s |
| Idle memory after the run | 71 MiB | 832 MiB |

Both are fast enough at this provisional size. Postgres was faster and used substantially less
memory in this small single-node test.

## Why Postgres wins for this pilot

### One recovery story

Ingot already needs its own immutable event log because identity decisions, review cases, and
explanations are domain events. With Postgres, that log can rebuild every read table and preserves
the original `recorded_at` values.

XTDB also has its own transaction log and indexed object storage. A production deployment must keep
those stores consistent during backup and restore. Replaying only Ingot's log into a fresh XTDB
database would assign new system times unless the import also recreates system time deliberately.
That makes disaster recovery harder to explain and test.

### Fewer moving parts

Postgres gives the pilot one service, one migration path, one backup toolchain, and one place to
inspect incidents. Production XTDB can require a durable log plus object storage; a standalone
container is explicitly a non-production setup.

### We can contain the extra SQL complexity

Application code must not copy the temporal predicate around. The persistence layer will expose one
shared two-clock query shape, and contract tests will run the temporal matrix against every
historical read path.

## Implementation rules

1. The server assigns `recorded_at`; clients cannot backdate when Ingot learned something.
2. Source data supplies effective intervals.
3. Corrections append a new revision. They never update or delete old event-log rows.
4. Identity membership, attributes, edges, media, and steward decisions use both clocks.
5. Current tables and indexes are disposable projections; the event log remains authoritative.
6. A clean database must rebuild to byte-equivalent API results from the event log.

## Implemented pilot read model

The API now stores events as tagged JSONB with explicit `recorded_at`, `valid_from`, and `valid_to`
columns. Erlang-term payloads and the single global snapshot are gone. One transactional projection
checkpoint covers indexed, rebuildable tables for:

- current claims and source records;
- code ownership and identity members;
- tombstones and redirects;
- golden records and edges;
- review cases and supplemental per-entity projection entries.

`Api.Store.rebuild!/0` reads the log in 5,000-event pages with no total-event limit, folds from an
empty state, compares the result with the indexed state, and recreates every projection table.
Current product and code reads use the per-key indexes; explicit two-clock reads still fold the
authoritative history.

The reproducible check is `MIX_ENV=test mix run bench/read_models.exs`. On the same local
Apple-Silicon/Postgres setup used for the spike, 200,000 projected records produced:

| Indexed lookup | Result |
| --- | ---: |
| Legacy-id median | 0.451 ms |
| Legacy-id p95 | 0.721 ms |
| Legacy-id maximum | 3.511 ms |
| Code lookup | 0.493 ms |

The benchmark fails above 50 ms at p95 or for the code lookup. This is a pilot guardrail, not a
general production capacity claim.

## When to reconsider XTDB

Re-run this decision only if temporal query complexity remains a dominant source of defects after
the shared Postgres query layer exists, or if the product needs large-scale temporal analytics that
the indexed pilot read models cannot serve.
