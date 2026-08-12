# Production pilot runbook

## Release gate

Before a pilot image is promoted:

```bash
mix test
cd api
mix test
mix format --check-formatted
mix hex.audit
mix deps.unlock --check-unused
cd ../php
composer test
composer audit --locked --no-interaction
```

CI also builds the release image, waits for `/ready`, and exercises authenticated metadata.

## Startup and probes

`Api.Bootstrap` is an ordered supervisor child. Its `start_link` returns only after migrations and
any required event-log replay finish, so Bandit cannot bind early. Applied schema versions are
recorded in `schema_migrations`.

- `/health`: process liveness only; no dependency calls.
- `/ready`: database connection, required event/projection tables, event offset, projection offset.
- Docker health checks `/ready`.

Every non-probe request receives `x-request-id` and is logged with method, path, status, and
duration. Store append and rebuild emit `[:ingot, :store, :append | :rebuild]` telemetry events and
structured duration/status logs. Alert if readiness fails, projection offset trails event offset,
write error rate is non-zero, or p95 exceeds the load target.

Production startup rejects short product/CSRF secrets, fewer than two steward principals, shared
steward credentials, or a product token reused on the steward surface.

## Capacity target

The pilot assumption is 50 current reads/second and one source refresh/second. The release gate is
twice that peak for ten seconds:

```bash
cd api
API_BASE=http://localhost:4000 \
PRODUCT_API_TOKEN=local-product-token-change-me-000001 \
mix run --no-start bench/http_load.exs
```

The check fails on any non-200 response or p95 above 250 ms. Local release result on 2026-07-10:

```json
{"seconds":10,"requests":1020,"errors":0,"reads_per_second":100,"writes_per_second":2,"p95_ms":214.137,"max_ms":1029.716}
```

Every benchmark run uses new source-record references, so the write load exercises event
persistence and projection updates rather than idempotent no-ops.

The 200,000-record indexed-read check is separate:

```bash
MIX_ENV=test mix run bench/read_models.exs
```

Latest result: 0.615 ms p95 for legacy-id lookup and 0.402 ms for code lookup.

## Backup, restore, replay

The pilot database is PostgreSQL 16 and the release image includes matching PostgreSQL 16 client
tools. `pg_dump` must have the same major version as the server. Backups are custom-format,
owner/ACL-neutral, mode 0600, and accompanied by SHA-256:

```bash
DATABASE_URL=... api/scripts/backup.sh /secure/ingot.dump
```

Never restore over the live database. Create a disposable target, then run:

```bash
DATABASE_URL="$SOURCE_DATABASE_URL" \
RESTORE_DATABASE_URL="$DISPOSABLE_DATABASE_URL" \
INGOT_RELEASE=bin/golden_record_api \
api/scripts/restore-replay-drill.sh
```

The restore command resolves both database identities and refuses to continue when source and
target are the same. Direct use of `restore.sh` also requires the explicit
`INGOT_ALLOW_DESTRUCTIVE_RESTORE=yes` acknowledgement.

The drill verifies the checksum, restores, runs ordered migrations, rebuilds every projection from
the event log, and requires event, state, and checkpoint offsets to match.

Verified locally on 2026-07-10 against a 165-event log after the twice-peak write test:

```json
{"offset":165,"status":"verified","rebuild":"{:ok, {:ok, 165}}"}
```

Run this drill before pilot cutover and at least weekly during the pilot.

## Shadow parity and cutover

Do not route writes to Ingot during shadowing. Mirror the complete source refresh and all late
arrivals into Ingot, then compare legacy-id responses after each window:

1. Baseline full source refresh.
2. One changed source refresh with unchanged key/legacy lineage.
3. Late-arriving correction with an earlier `valid_from`.
4. Compare codes, attributes (including unresolved values), media, status, and legacy ID.
5. Classify every difference as expected policy divergence or unexplained.

`php/bench/dump_medipim_shadow_window.php` independently projects this window from the real medipim
fixtures. `Api.E2eMigrationTest` requires the HTTP API to match that committed PHP oracle after all
three phases, and the PHP suite proves the oracle is reproducible. A real pilot must repeat the same
comparison against the legacy production read API for at least one full source-refresh interval
plus its agreed late-arrival window. Limited read cutover is allowed only when unexplained
differences remain zero.

Start with a small allowlist of read-only legacy IDs. Keep the legacy read path as rollback.
Increase the allowlist only after readiness, error rate, latency, queue growth, and parity remain
within their gates.
