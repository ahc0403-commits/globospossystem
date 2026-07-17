#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_SCRIPT="$ROOT_DIR/scripts/deploy_pos_production.sh"
TMP_DIR="$(mktemp -d)"
ORIGIN_REPO="$TMP_DIR/origin.git"
REHEARSAL_REPO="$TMP_DIR/rehearsal"
WRONG_SOURCE_REPO="$TMP_DIR/wrong-source"
FAKE_BIN="$TMP_DIR/bin"
CALL_LOG="$TMP_DIR/calls.log"
HISTORY_STATE="$TMP_DIR/history-applied"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p \
  "$REHEARSAL_REPO/scripts" \
  "$REHEARSAL_REPO/supabase/.temp" \
  "$REHEARSAL_REPO/supabase/migrations" \
  "$REHEARSAL_REPO/test" \
  "$FAKE_BIN"
cp "$DEPLOY_SCRIPT" "$REHEARSAL_REPO/scripts/deploy_pos_production.sh"
cp "$ROOT_DIR/supabase/migrations/20260717090000_store_opening_setup_wizard.sql" \
  "$REHEARSAL_REPO/supabase/migrations/"
for store_setup_sql in \
  preflight_store_opening_setup_wizard.sql \
  apply_store_opening_setup_wizard.sql \
  verify_store_opening_setup_wizard.sql \
  rollback_store_opening_setup_wizard.sql; do
  cp "$ROOT_DIR/scripts/$store_setup_sql" "$REHEARSAL_REPO/scripts/"
done
printf '%s\n' ynriuoomotxuwhuxxmhj >"$REHEARSAL_REPO/supabase/.temp/project-ref"
printf 'name: db_only_rehearsal\nenvironment:\n  sdk: ^3.8.0\n' \
  >"$REHEARSAL_REPO/pubspec.yaml"
printf '{"packages":[]}\n' >"$REHEARSAL_REPO/pubspec.lock"
printf 'void main() {}\n' >"$REHEARSAL_REPO/test/focused_test.dart"
printf '.dart_tool/\n' >"$REHEARSAL_REPO/.gitignore"
printf '# Supabase CLI authentication is provided by the operator environment.\n' \
  >"$TMP_DIR/production.env"

cat >"$REHEARSAL_REPO/scripts/check_pilot_auth_accounts.sh" <<'EOF'
#!/usr/bin/env bash
printf 'pilot-auth-check\n' >>"$CALL_LOG"
exit 91
EOF
cat >"$REHEARSAL_REPO/scripts/smoke_pilot_login.sh" <<'EOF'
#!/usr/bin/env bash
printf 'pilot-login-smoke\n' >>"$CALL_LOG"
exit 92
EOF
chmod +x \
  "$REHEARSAL_REPO/scripts/check_pilot_auth_accounts.sh" \
  "$REHEARSAL_REPO/scripts/smoke_pilot_login.sh"

git init --bare --initial-branch=main "$ORIGIN_REPO" >/dev/null
git init --initial-branch=main "$REHEARSAL_REPO" >/dev/null
git -C "$REHEARSAL_REPO" config user.email deploy-test@globos.test
git -C "$REHEARSAL_REPO" config user.name 'Deploy Test'
git -C "$REHEARSAL_REPO" add .
git -C "$REHEARSAL_REPO" add -f supabase/.temp/project-ref
git -C "$REHEARSAL_REPO" commit -m 'DB-only fixture baseline' >/dev/null
git -C "$REHEARSAL_REPO" remote add origin "$ORIGIN_REPO"
git -C "$REHEARSAL_REPO" push --set-upstream origin main >/dev/null

cat >"$FAKE_BIN/flutter" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'flutter %s\n' "$*" >>"$CALL_LOG"
if [[ "$*" == 'pub get --enforce-lockfile' ]]; then
  mkdir -p .dart_tool
  printf '{"configVersion":2,"packages":[]}\n' >.dart_tool/package_config.json
  exit 0
fi
[[ "${1:-}" == test ]] || exit 81
[[ -f .dart_tool/package_config.json ]] || exit 82
EOF

cat >"$FAKE_BIN/dart" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'dart %s\n' "$*" >>"$CALL_LOG"
[[ "$*" == analyze ]] || exit 83
[[ -f .dart_tool/package_config.json ]] || exit 84
EOF

cat >"$FAKE_BIN/supabase" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'supabase %s\n' "$*" >>"$CALL_LOG"
case "$*" in
  'migration list')
    printf ' LOCAL          | REMOTE         | TIME\n'
    if [[ "${HISTORY_PRESET:-absent}" == present || -f "$HISTORY_STATE" ]]; then
      printf ' 20260717090000 | 20260717090000 | 2026-07-17\n'
    else
      printf ' 20260717090000 |                |\n'
    fi
    ;;
  'migration repair 20260717090000 --status applied --yes')
    if [[ "${REPAIR_DOES_NOT_PERSIST:-0}" != 1 ]]; then
      : >"$HISTORY_STATE"
    fi
    ;;
  'db dump --linked --schema public --dry-run')
    cat <<EXPORTS
export PGHOST="${FAKE_PGHOST:-aws-0-ap-southeast-1.pooler.supabase.com}"
export PGPORT="${FAKE_PGPORT:-5432}"
export PGUSER="postgres.ynriuoomotxuwhuxxmhj"
export PGPASSWORD="x"
export PGDATABASE="postgres"
EXPORTS
    ;;
  *)
    exit 85
    ;;
esac
EOF

cat >"$FAKE_BIN/psql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sql_file=''
while [[ $# -gt 0 ]]; do
  if [[ "$1" == --file ]]; then
    shift
    sql_file="${1:-}"
    break
  fi
  shift
done
[[ -n "$sql_file" ]] || exit 86
sql_name="$(basename "$sql_file")"
printf 'psql %s\n' "$sql_name" >>"$CALL_LOG"
[[ "${FAIL_SQL_PHASE:-}" != "$sql_name" ]] || exit 87
EOF
chmod +x "$FAKE_BIN/flutter" "$FAKE_BIN/dart" "$FAKE_BIN/supabase" "$FAKE_BIN/psql"

export PATH="$FAKE_BIN:$PATH"
export CALL_LOG HISTORY_STATE
export TEST_TARGETS=all
export ENV_FILE="$TMP_DIR/production.env"
export PILOT_AUTH_EMAILS_FILE="$TMP_DIR/missing-pilot-emails"
export PILOT_LOGIN_SMOKE_SCRIPT="$REHEARSAL_REPO/scripts/smoke_pilot_login.sh"

invoke_db_only() {
  local repo="$1"
  shift
  bash "$repo/scripts/deploy_pos_production.sh" \
    --migration supabase/migrations/20260717090000_store_opening_setup_wizard.sql \
    --mode prebuilt \
    --db-only \
    --yes \
    "$@"
}

assert_failure() {
  local expected="$1"
  shift
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"$expected"* ]]
}

: >"$CALL_LOG"
rm -f "$HISTORY_STATE"
success_output="$(invoke_db_only "$REHEARSAL_REPO" 2>&1)"
[[ "$success_output" == *'Pilot Auth/account readiness: N/A (not invoked; no pilot credentials required).'* ]]
[[ "$success_output" == *'Vercel deployment: N/A.'* ]]
[[ "$success_output" == *'Live HTTP check: N/A.'* ]]
[[ "$success_output" == *'Pilot login smoke: N/A (not invoked).'* ]]
[[ "$success_output" == *'DB-only releases do not establish or claim POS login readiness.'* ]]
[[ "$success_output" != *'PILOT_SMOKE_EMAIL is required'* ]]
[[ "$success_output" != *'PILOT_SMOKE_PASSWORD is required'* ]]
[[ "$(cat "$CALL_LOG")" != *pilot-auth-check* ]]
[[ "$(cat "$CALL_LOG")" != *pilot-login-smoke* ]]
[[ "$(cat "$CALL_LOG")" != *vercel* ]]
cat >"$TMP_DIR/expected-db-sequence.log" <<'EOF'
psql preflight_store_opening_setup_wizard.sql
psql apply_store_opening_setup_wizard.sql
psql verify_store_opening_setup_wizard.sql
EOF
grep '^psql ' "$CALL_LOG" >"$TMP_DIR/actual-db-sequence.log"
cmp "$TMP_DIR/expected-db-sequence.log" "$TMP_DIR/actual-db-sequence.log"
grep -qx 'supabase migration repair 20260717090000 --status applied --yes' "$CALL_LOG"

export ENV_FILE="$TMP_DIR/missing-production-env"
assert_failure 'Missing env file.' invoke_db_only "$REHEARSAL_REPO"
export ENV_FILE="$TMP_DIR/production.env"

for rejected_pooler in direct transaction; do
  : >"$CALL_LOG"
  rm -f "$HISTORY_STATE"
  if [[ "$rejected_pooler" == direct ]]; then
    export FAKE_PGHOST=db.ynriuoomotxuwhuxxmhj.supabase.co
    export FAKE_PGPORT=5432
  else
    export FAKE_PGHOST=aws-0-ap-southeast-1.pooler.supabase.com
    export FAKE_PGPORT=6543
  fi
  assert_failure 'DB-only requires the Supabase Shared Session Pooler on port 5432.' \
    invoke_db_only "$REHEARSAL_REPO"
  [[ "$(cat "$CALL_LOG")" != *'psql apply_store_opening_setup_wizard.sql'* ]]
  [[ "$(cat "$CALL_LOG")" != *'migration repair'* ]]
  unset FAKE_PGHOST FAKE_PGPORT
done

assert_failure '--db-only requires --migration FILE.' \
  bash "$DEPLOY_SCRIPT" --db-only --dry-run --yes
assert_failure '--db-only requires --migration FILE.' \
  env MIGRATION_FILE=supabase/migrations/20260717090000_store_opening_setup_wizard.sql \
    bash "$DEPLOY_SCRIPT" --db-only --dry-run --yes
for incompatible_option in \
  --skip-db \
  --skip-auth-check \
  --skip-login-smoke \
  --skip-vercel \
  --skip-build \
  --skip-checks \
  --no-tests \
  --rollback-hierarchy; do
  assert_failure "--db-only is incompatible with $incompatible_option" \
    bash "$DEPLOY_SCRIPT" \
      --migration supabase/migrations/20260717090000_store_opening_setup_wizard.sql \
      --db-only "$incompatible_option" --dry-run --yes
done
assert_failure '--db-only is incompatible with non-default deployment mode remote.' \
  bash "$DEPLOY_SCRIPT" \
    --migration supabase/migrations/20260717090000_store_opening_setup_wizard.sql \
    --db-only --mode remote --dry-run --yes

: >"$CALL_LOG"
rm -f "$HISTORY_STATE"
export TEST_TARGETS=test/missing_db_only_test.dart
assert_failure 'DB-only test target not found: test/missing_db_only_test.dart' \
  invoke_db_only "$REHEARSAL_REPO"
export TEST_TARGETS=all
[[ "$(cat "$CALL_LOG")" != *'psql '* ]]

printf 'dirty\n' >"$REHEARSAL_REPO/dirty.txt"
assert_failure 'Refusing to deploy dirty worktree.' \
  invoke_db_only "$REHEARSAL_REPO" --dry-run
rm -f "$REHEARSAL_REPO/dirty.txt"

git clone --quiet "$ORIGIN_REPO" "$WRONG_SOURCE_REPO"
git -C "$WRONG_SOURCE_REPO" config user.email deploy-test@globos.test
git -C "$WRONG_SOURCE_REPO" config user.name 'Deploy Test'
printf 'wrong source\n' >"$WRONG_SOURCE_REPO/wrong-source.txt"
git -C "$WRONG_SOURCE_REPO" add wrong-source.txt
git -C "$WRONG_SOURCE_REPO" commit -m 'wrong source fixture' >/dev/null
assert_failure 'Production deployment requires exact HEAD == freshly fetched origin/main.' \
  invoke_db_only "$WRONG_SOURCE_REPO" --dry-run

printf '%s\n' wrongprojectref >"$REHEARSAL_REPO/supabase/.temp/project-ref"
assert_failure 'Linked Supabase project is not POS production' \
  bash -c '
    source "$1/scripts/deploy_pos_production.sh"
    DB_ONLY=1
    DRY_RUN=1
    REQUIRE_CLEAN_GIT=0
    TEST_TARGETS=all
    preflight
  ' wrong-target "$REHEARSAL_REPO"
printf '%s\n' ynriuoomotxuwhuxxmhj >"$REHEARSAL_REPO/supabase/.temp/project-ref"

: >"$CALL_LOG"
rm -f "$HISTORY_STATE"
export HISTORY_PRESET=present
assert_failure 'Remote migration history already contains 20260717090000.' \
  invoke_db_only "$REHEARSAL_REPO"
unset HISTORY_PRESET
[[ "$(cat "$CALL_LOG")" != *'psql '* ]]
[[ "$(cat "$CALL_LOG")" != *'migration repair'* ]]

: >"$CALL_LOG"
rm -f "$HISTORY_STATE"
export REPAIR_DOES_NOT_PERSIST=1
assert_failure 'Remote migration history does not contain 20260717090000.' \
  invoke_db_only "$REHEARSAL_REPO"
unset REPAIR_DOES_NOT_PERSIST
grep -qx 'supabase migration repair 20260717090000 --status applied --yes' "$CALL_LOG"

for failed_phase in \
  preflight_store_opening_setup_wizard.sql \
  apply_store_opening_setup_wizard.sql \
  verify_store_opening_setup_wizard.sql; do
  : >"$CALL_LOG"
  rm -f "$HISTORY_STATE"
  export FAIL_SQL_PHASE="$failed_phase"
  assert_failure 'failed.' invoke_db_only "$REHEARSAL_REPO"
  unset FAIL_SQL_PHASE
  [[ "$(cat "$CALL_LOG")" != *'migration repair'* ]]
  case "$failed_phase" in
    preflight_*)
      [[ "$(cat "$CALL_LOG")" != *'psql apply_store_opening_setup_wizard.sql'* ]]
      ;;
    apply_*)
      [[ "$(cat "$CALL_LOG")" != *'psql verify_store_opening_setup_wizard.sql'* ]]
      ;;
  esac
done

printf 'PASS: DB-only release excludes account/Vercel work and fails closed through guarded SQL phases\n'
