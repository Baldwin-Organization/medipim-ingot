#!/bin/sh
set -eu

: "${DATABASE_URL:?DATABASE_URL is required}"

destination="${1:-ingot-$(date -u +%Y%m%dT%H%M%SZ).dump}"
umask 077

pg_dump \
  --dbname="$DATABASE_URL" \
  --format=custom \
  --compress=9 \
  --no-owner \
  --no-acl \
  --file="$destination"

openssl dgst -sha256 "$destination" >"$destination.sha256"
printf 'backup=%s\nchecksum=%s\n' "$destination" "$destination.sha256"
