#!/bin/sh
set -eu

: "${RESTORE_DATABASE_URL:?RESTORE_DATABASE_URL is required and must name a disposable target database}"
: "${DATABASE_URL:?DATABASE_URL is required to protect the source database}"

if test "${INGOT_ALLOW_DESTRUCTIVE_RESTORE:-}" != "yes"; then
  echo "refusing destructive restore: set INGOT_ALLOW_DESTRUCTIVE_RESTORE=yes" >&2
  exit 1
fi

database_identity() {
  psql "$1" -v ON_ERROR_STOP=1 -Atc \
    "SELECT current_database() || '@' || COALESCE(inet_server_addr()::text, 'local') || ':' || COALESCE(inet_server_port()::text, 'local')"
}

source_identity="$(database_identity "$DATABASE_URL")"
target_identity="$(database_identity "$RESTORE_DATABASE_URL")"

if test "$source_identity" = "$target_identity"; then
  echo "refusing restore: source and target are the same database ($source_identity)" >&2
  exit 1
fi

backup="${1:?usage: restore.sh BACKUP.dump}"
test -f "$backup"

if test -f "$backup.sha256"; then
  expected="$(cut -d' ' -f2- "$backup.sha256")"
  actual="$(openssl dgst -sha256 "$backup" | cut -d' ' -f2-)"
  test "$actual" = "$expected" || {
    echo "backup checksum mismatch" >&2
    exit 1
  }
fi

pg_restore \
  --dbname="$RESTORE_DATABASE_URL" \
  --clean \
  --if-exists \
  --no-owner \
  --no-acl \
  "$backup"

psql "$RESTORE_DATABASE_URL" -v ON_ERROR_STOP=1 -Atc \
  "SELECT 'events=' || count(*) FROM events"
