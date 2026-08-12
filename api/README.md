# Ingot API

Ingot turns changing source records into stable golden records. A source owns an atomic record,
identified by `{source, ref}`. Each new revision says whether to replace, patch, withdraw, or
reactivate that record. Ingot keeps the history, preserves stable IDs, and asks a human instead of
guessing when evidence is contradictory.

Contract: `openapi.yaml` · JSON Schemas and executable examples: `../contract/` · detailed guide:
`../docs/API.md`.

```bash
# the whole stack (from the repo root)
docker compose -f api/docker-compose.yml up --build     # API on :4000, Postgres included

# development
docker run -d --name gr-api-test-pg -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:16-alpine
cd api && mix deps.get && mix test                      # incl. the E2E truth suite
iex -S mix                                              # dev server on :4000
```

The local Compose stack uses:

- Product token: `local-product-token-change-me-000001`
- Steward `sam`: Bearer `local-sam-token-change-me-000001`, Basic password `local-sam-password-change-me`
- Steward `alex`: Bearer `local-alex-token-change-me-000001`, Basic password `local-alex-password-change-me`

## 1. A clean merge

Two source listings share a strong code, so they become one identity. No manual action is needed.

```bash
curl -s localhost:4000/v1/claims \
  -H 'Authorization: Bearer local-product-token-change-me-000001' \
  -H 'Content-Type: application/json' \
  -d '{"claims":[
    {"kind":"identity","source":"manufacturer","ref":"M-1","codes":["cnk:1000001","gtin:05012345678900"]},
    {"kind":"identity","source":"supplier","ref":"S-1","codes":["cnk:1000001","supplier_ref:S-1"]}
  ]}'
```

The response contains one minted key. Inspect its current status:

```bash
curl -s localhost:4000/v1/identities/SK_1 \
  -H 'Authorization: Bearer local-product-token-change-me-000001'
```

## 2. A contradiction

Two equally trusted sources disagree. The product returns `value: null`, `winner: null`, and
`status: "needs_review"`; the review queue contains a case with the exact evidence offset.

```bash
curl -s localhost:4000/v1/claims \
  -H 'Authorization: Bearer local-product-token-change-me-000001' \
  -H 'Content-Type: application/json' \
  -d '{"claims":[
    {"kind":"identity","source":"manufacturer","ref":"M-2","codes":["cnk:1000002"]},
    {"kind":"attribute","source":"manufacturer","code":"cnk:1000002","field":"color","value":"ivory"},
    {"kind":"attribute","source":"supplier","code":"cnk:1000002","field":"color","value":"white"}
  ]}'

curl -s localhost:4000/steward/v1/queue \
  -H 'Authorization: Bearer local-sam-token-change-me-000001'
```

The decision body uses the queue's `case_id` and `evidence_offset`. The actor is `sam` because of
the credential; clients cannot submit a `by` name.

## 3. A late correction

The supplier sends a correction today that became true in February. `known_at` asks what Ingot
knew at an instant; `effective_at` asks what was true on a real-world date.

```bash
curl -s -X PUT localhost:4000/v1/source-records/supplier/P-3/revisions/1 \
  -H 'Authorization: Bearer local-product-token-change-me-000001' -H 'Content-Type: application/json' \
  -d '{"operation":"replace","valid_from":"2026-01-01","claims":[
    {"kind":"identity","codes":["cnk:1000003"]},
    {"kind":"attribute","code":"cnk:1000003","field":"name","value":"Old spelling"}
  ]}'

curl -s -X PUT localhost:4000/v1/source-records/supplier/P-3/revisions/2 \
  -H 'Authorization: Bearer local-product-token-change-me-000001' -H 'Content-Type: application/json' \
  -d '{"operation":"replace","base_revision":"1","valid_from":"2026-02-01","claims":[
    {"kind":"identity","codes":["cnk:1000003"]},
    {"kind":"attribute","code":"cnk:1000003","field":"name","value":"Corrected spelling"}
  ]}'
```

Query the returned `legacy_id` with `effective_at=2026-01-15` to see the old spelling, and with
`effective_at=2026-02-15` to see the correction. Add `known_at=<RFC3339>` to reproduce what the
system could answer before or after receiving it.

## Useful endpoints

- `POST /v1/dry-run` — run the claims pipeline without writing anything.
- `PUT /v1/source-records/{source}/{ref}/revisions/{revision}` — source lifecycle.
- `GET /v1/products/{legacy_id}` — current or two-clock golden record.
- `GET /v1/identities/{key}` — active, merged, or withdrawn identity status.
- `GET /v1/changes?since=0&limit=500` — paginated event feed.
- `GET /v1/metadata` — active registry, survivorship, review, and temporal policy.
- `GET /steward/v1/queue` — evidence-bound review cases.

Layout: `lib/api/store.ex` owns the JSON event log; `read_models.ex` owns disposable indexed
projections; `writes.ex` applies source revisions; `reads.ex` serves current and two-clock reads;
`steward.ex` applies authenticated case decisions.

The engine stays dependency-free; Bandit, Plug, and Postgrex live only in this API application.
