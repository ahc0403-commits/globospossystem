#!/usr/bin/env bash
set -euo pipefail
if ! command -v initdb >/dev/null 2>&1 && command -v pg_config >/dev/null 2>&1; then
  export PATH="$(pg_config --bindir):$PATH"
fi
attendance_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
attendance_tmp="$(mktemp -d "${TMPDIR:-/tmp}/attendance-storage.XXXXXX")"
attendance_port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)"
cleanup() {
  pg_ctl -D "$attendance_tmp/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$attendance_tmp"
}
trap cleanup EXIT
initdb -D "$attendance_tmp/data" --auth=trust --encoding=UTF8 --locale=C >/dev/null
pg_ctl -D "$attendance_tmp/data" -l "$attendance_tmp/server.log" \
  -o "-h 127.0.0.1 -p $attendance_port -k $attendance_tmp" -w start >/dev/null
run_sql() {
  psql -X -h 127.0.0.1 -p "$attendance_port" -d postgres -v ON_ERROR_STOP=1 -f "$1"
}
run_sql "$attendance_root/test/sql/attendance_storage_policy_setup.sql" >/dev/null
run_sql "$attendance_root/scripts/preflight_attendance_storage_policy_rebind.sql" >/dev/null
run_sql "$attendance_root/supabase/migrations/20261015023000_attendance_storage_policy_rebind.sql" >/dev/null
run_sql "$attendance_root/scripts/verify_attendance_storage_policy_rebind.sql" >/dev/null
run_sql "$attendance_root/test/sql/attendance_storage_policy_test.sql" >/dev/null
printf 'ATTENDANCE_STORAGE_POLICY_TEST=PASS\n'
