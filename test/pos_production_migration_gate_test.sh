#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
FIXTURE_SCRIPTS="$TMP_DIR/scripts"
FIXTURE_MIGRATIONS="$TMP_DIR/migrations"
CALL_LOG="$TMP_DIR/calls.log"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$FIXTURE_SCRIPTS" "$FIXTURE_MIGRATIONS"

fail() { printf 'ERROR: %s\n' "$1" >&2; return 1; }
log() { printf '%s\n' "$1"; }
require_migration_history_absent() { printf 'history-absent %s\n' "$1" >>"$CALL_LOG"; }
require_migration_history_present() { printf 'history-present %s\n' "$1" >>"$CALL_LOG"; }
run_linked_psql_file() { printf 'sql %s\n' "$(basename "$1")" >>"$CALL_LOG"; }
run() { printf 'run %s\n' "$*" >>"$CALL_LOG"; }

# shellcheck source=scripts/lib/production_migration_gate.sh
source "$ROOT_DIR/scripts/lib/production_migration_gate.sh"

printf '%s\n' '-- migration' >"$FIXTURE_MIGRATIONS/20260805010000_standard_gate.sql"
printf '%s\n' '-- preflight' >"$FIXTURE_SCRIPTS/preflight_standard_gate.sql"
printf '%s\n' '-- guarded apply' >"$FIXTURE_SCRIPTS/apply_standard_gate.sql"
printf '%s\n' '-- verification' >"$FIXTURE_SCRIPTS/verify_standard_gate.sql"
printf '%s\n' '-- rollback' >"$FIXTURE_SCRIPTS/rollback_standard_gate.sql"

SKIP_DB=0
DRY_RUN=0
apply_migration_by_convention \
  "$FIXTURE_MIGRATIONS/20260805010000_standard_gate.sql" \
  "$FIXTURE_SCRIPTS"

cat >"$TMP_DIR/expected.log" <<'EOF'
history-absent 20260805010000
sql preflight_standard_gate.sql
sql apply_standard_gate.sql
sql verify_standard_gate.sql
run supabase migration repair 20260805010000 --status applied --yes
history-present 20260805010000
EOF
cmp "$TMP_DIR/expected.log" "$CALL_LOG"

printf '%s\n' \
  '-- production-gate: self-verifying' \
  '-- inline DO block verifies postconditions' \
  >"$FIXTURE_MIGRATIONS/20260805020000_embedded_gate.sql"
: >"$CALL_LOG"
apply_migration_by_convention \
  "$FIXTURE_MIGRATIONS/20260805020000_embedded_gate.sql" \
  "$FIXTURE_SCRIPTS"
grep -qx 'sql 20260805020000_embedded_gate.sql' "$CALL_LOG"
! grep -q 'verify_embedded_gate.sql' "$CALL_LOG"

printf '%s\n' '-- migration without verification' \
  >"$FIXTURE_MIGRATIONS/20260805030000_unverified_gate.sql"
set +e
unverified_output="$(
  apply_migration_by_convention \
    "$FIXTURE_MIGRATIONS/20260805030000_unverified_gate.sql" \
    "$FIXTURE_SCRIPTS" 2>&1
)"
unverified_status=$?
set -e
[[ "$unverified_status" -ne 0 ]]
[[ "$unverified_output" == *'requires '*'verify_unverified_gate.sql or an explicit self-verifying contract'* ]]

printf '%s\n' '-- malformed' >"$FIXTURE_MIGRATIONS/manual_name.sql"
set +e
malformed_output="$(
  resolve_production_migration_gate \
    "$FIXTURE_MIGRATIONS/manual_name.sql" "$FIXTURE_SCRIPTS" 2>&1
)"
malformed_status=$?
set -e
[[ "$malformed_status" -ne 0 ]]
[[ "$malformed_output" == *'must use TIMESTAMP_snake_case.sql'* ]]

printf 'PASS: convention-based production migration gate\n'
