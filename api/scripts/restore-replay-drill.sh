#!/bin/sh
set -eu

: "${DATABASE_URL:?DATABASE_URL must point at the source database}"
: "${RESTORE_DATABASE_URL:?RESTORE_DATABASE_URL must point at a disposable, pre-created target}"

release="${INGOT_RELEASE:-bin/golden_record_api}"
work="${TMPDIR:-/tmp}/ingot-restore-drill-$$.dump"
trap 'rm -f "$work" "$work.sha256"' EXIT

"$(dirname "$0")/backup.sh" "$work"
INGOT_ALLOW_DESTRUCTIVE_RESTORE=yes "$(dirname "$0")/restore.sh" "$work"

PRODUCT_API_TOKEN="${PRODUCT_API_TOKEN:-restore-drill-product-token-000001}"
CSRF_SECRET="${CSRF_SECRET:-restore-drill-csrf-secret-000001}"

if test -z "${STEWARD_CREDENTIALS_JSON:-}"; then
  STEWARD_CREDENTIALS_JSON='{"drill-a":{"bearer":["restore-drill-steward-a-000001"],"password":"restore-drill-password-a"},"drill-b":{"bearer":["restore-drill-steward-b-000001"],"password":"restore-drill-password-b"}}'
fi

export PRODUCT_API_TOKEN CSRF_SECRET STEWARD_CREDENTIALS_JSON

DATABASE_URL="$RESTORE_DATABASE_URL" \
"$release" eval '
  {:ok, _applications} = Application.ensure_all_started(:postgrex)
  db_opts =
    Application.fetch_env!(:golden_record_api, :db)
    |> Keyword.merge(name: Api.DB, pool_size: 2)
  {:ok, _pid} = Postgrex.start_link(db_opts)
  Api.Store.migrate!()
  result = Api.Store.rebuild!()
  state = Api.Store.state()
  event_offset =
    case Postgrex.query!(Api.DB, ~s|SELECT COALESCE(max("offset"), 0) FROM events|, []) do
      %{rows: [[offset]]} -> offset
    end
  if state.offset != event_offset or Api.ReadModels.checkpoint_offset() != event_offset,
    do: raise("restore replay offset mismatch")
  IO.puts(JSON.encode!(%{rebuild: inspect(result), offset: event_offset, status: "verified"}))
'
