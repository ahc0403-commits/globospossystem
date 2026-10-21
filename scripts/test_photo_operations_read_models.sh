#!/usr/bin/env bash
set -euo pipefail
if ! command -v initdb >/dev/null 2>&1 && command -v pg_config >/dev/null 2>&1; then
  export PATH="$(pg_config --bindir):$PATH"
fi
for photo_tool in initdb pg_ctl psql; do
  command -v "$photo_tool" >/dev/null || { echo "Missing fixture tool: $photo_tool" >&2; exit 1; }
done
photo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
photo_tmp="$(mktemp -d "${TMPDIR:-/tmp}/photo-operations.XXXXXX")"
cleanup() {
  pg_ctl -D "$photo_tmp/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$photo_tmp"
}
trap cleanup EXIT
initdb -D "$photo_tmp/data" --auth=trust --encoding=UTF8 --locale=C >/dev/null
# Unix socket only: no network listener, no production/project credentials.
pg_ctl -D "$photo_tmp/data" -l "$photo_tmp/server.log" -o "-h '' -k $photo_tmp" -w start >/dev/null
for photo_sql in scripts/tests/photo_operations/setup.sql supabase/migrations/20261021020000_office_photo_operations_read_models.sql scripts/tests/photo_operations/verify.sql; do
  psql -X -h "$photo_tmp" -d postgres -v ON_ERROR_STOP=1 -f "$photo_root/$photo_sql"
done
