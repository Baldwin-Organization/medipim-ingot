# Ingot API contract

The executable contract is `api/openapi.yaml`. JSON Schemas and executable examples live in
`contract/`. This page explains the model in plain language.

## Credentials

| Surface | Credential |
| --- | --- |
| `/v1/...` | `Authorization: Bearer $PRODUCT_API_TOKEN` |
| `/steward/v1/...` | individual Bearer token from `STEWARD_CREDENTIALS_JSON` |
| `/steward` HTML | individual HTTP Basic username/password from the same configuration |

The authenticated steward principal is the actor. Decision bodies do not choose a `by` name.
`GET /health` (process liveness) and `GET /ready` (database and projection readiness) are
unauthenticated so infrastructure probes can call them.

## Write source records, not partial entities

`PUT /v1/source-records/{source}/{ref}/revisions/{revision}` changes one atomic source record.

- `replace`: the submitted snapshot replaces that source record; omitted facts disappear.
- `patch`: `upsert` changes named facts and `remove` deletes named facts.
- `withdraw`: all contributions disappear, but the key and legacy ID remain recoverable.
- `reactivate`: restores the record on the same identity.

Revision numbers are idempotent. Replaying identical content returns the prior result. Reusing a
revision with different content, or patching the wrong `base_revision`, returns `409`.

The server controls `recorded_at` (when Ingot learned the revision). The source controls
`valid_from` and optional exclusive `valid_to` (when it is true in the real world).

`POST /v1/claims` remains the lower-level canonical-claims endpoint. `POST /v1/dry-run` executes
the same validation and identity pipeline without committing. `POST /v1/cutover` commits a
convergent migration batch. Contract-C history remains available at `/v1/backfill/envelopes`.

## Read with two independent clocks

These endpoints accept both query parameters:

- `known_at=<RFC3339 timestamp>`: only use facts Ingot had recorded by that instant.
- `effective_at=<ISO date>`: only use facts valid on that real-world date.

Endpoints:

- `GET /v1/products/{legacy_id}`
- `GET /v1/products/by-code/{scheme}/{value}`
- `GET /v1/source-records/{source}/{ref}`

Omitting both clocks uses indexed current read models. `as_of=YYYY-MM-DD` on the legacy product
route is a compatibility alias that sets both clocks to the same date.

An unresolved attribute is explicit:

```json
{
  "field": "color",
  "value": null,
  "winner": null,
  "status": "needs_review",
  "candidates": [
    {"source": "manufacturer", "value": "ivory"},
    {"source": "supplier", "value": "white"}
  ]
}
```

`GET /v1/identities/{key}` reports `active`, `merged`, or `withdrawn`, the current redirect target,
lane, codes, and every legacy ID. `GET /v1/metadata` reports the active scheme/relation vocabulary,
survivorship configuration, review policy, and clock formats.

## Paginated events

`GET /v1/changes?since={offset}&limit={1..1000}` returns events with offset strictly greater than
`since`. `next` is the next cursor. The feed includes source-record lifecycle, identity, review
case, endorsement, and final decision events.

## Evidence-bound review

`GET /steward/v1/queue` returns open merge, attribute, and repair cases. Every item includes:

- `case_id`
- `evidence_offset`
- the members, claims, candidates, or codes the steward must inspect

`POST /steward/v1/decisions` requires an individual Bearer credential. Merge, split, and suppress
need two distinct authenticated principals reviewing the same open case and evidence offset.
Changed evidence, a closed case, the wrong target, cross-lane operations, and same-person double
approval are rejected. Browser forms additionally require a CSRF token.

## Errors

Errors use an HTTP status plus an `error` string. Stable machine-readable paths may also include a
`code` (for example `identity_not_found`). Batch validation uses:

```json
{"errors": [{"index": 1, "error": "field-specific explanation"}]}
```

No rejected batch or decision appends partial events.

## Operations

Required production environment:

- `DATABASE_URL`
- `PRODUCT_API_TOKEN`
- `STEWARD_CREDENTIALS_JSON`
- `CSRF_SECRET`

Optional: `PORT`, `STEWARD_PORT`, `MAX_CLAIMS_PER_BATCH`, `MAX_ENVELOPES_PER_BATCH`, and
`SOURCE_PRIORITY_JSON`.

Postgres stores tagged JSONB events with explicit recorded/valid times. Disposable indexed tables
serve current claims, ownership, members, tombstones, redirects, golden records, edges, review
cases, and checkpoints. `Api.Store.rebuild!/0` pages through the complete event log and recreates
them. See `docs/STORAGE_FOUNDATION.md`.
