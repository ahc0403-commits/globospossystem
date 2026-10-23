#!/usr/bin/env bash
set -euo pipefail
PHOTO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v pg_config >/dev/null; then export PATH="$(pg_config --bindir):$PATH";fi
PHOTO_TMP="$(mktemp -d)"
PHOTO_PORT="$((31000 + RANDOM % 1000))"
trap 'pg_ctl -D "$PHOTO_TMP/db" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$PHOTO_TMP"' EXIT
initdb -D "$PHOTO_TMP/db" --auth=trust --username=postgres >/dev/null
pg_ctl -D "$PHOTO_TMP/db" -o "-h 127.0.0.1 -p $PHOTO_PORT" -w start >/dev/null
createdb -U postgres -h 127.0.0.1 -p "$PHOTO_PORT" photo_operations
PHOTO_PSQL=(psql -U postgres -h 127.0.0.1 -p "$PHOTO_PORT" -d photo_operations -X -v ON_ERROR_STOP=1)
"${PHOTO_PSQL[@]}" -f "$PHOTO_ROOT/test/fixtures/photo_office_base_setup.sql" >/dev/null
"${PHOTO_PSQL[@]}" -f "$PHOTO_ROOT/test/fixtures/photo_office_operations_setup.sql" >/dev/null
"${PHOTO_PSQL[@]}" -f "$PHOTO_ROOT/scripts/preflight_photo_office_operations.sql"
"${PHOTO_PSQL[@]}" -f "$PHOTO_ROOT/supabase/migrations/20261023100000_photo_office_operations.sql" >/dev/null
"${PHOTO_PSQL[@]}" -f "$PHOTO_ROOT/scripts/verify_photo_office_operations.sql"
"${PHOTO_PSQL[@]}" -f "$PHOTO_ROOT/test/photo_office_operations_test.sql"
