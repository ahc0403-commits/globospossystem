#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_SCRIPT="$ROOT_DIR/scripts/deploy_pos_production.sh"
REAL_PSQL="$(command -v psql)"
REAL_CREATEDB="$(command -v createdb)"
TMP_DIR="$(mktemp -d)"
FAKE_BIN="$TMP_DIR/bin"
ISSUER_LOG="$TMP_DIR/issuer.log"
PSQL_LOG="$TMP_DIR/psql.log"
SECRET='temporary-secret-must-never-appear'
PG_CONTAINER="globos-pos-deploy-test-$$"
LOCAL_PGHOST=127.0.0.1

cleanup() {
  docker rm -f "$PG_CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN"
docker run --detach --rm \
  --name "$PG_CONTAINER" \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  --publish 127.0.0.1::5432 \
  postgres:15 >/dev/null
PORT="$(docker port "$PG_CONTAINER" 5432/tcp | sed 's/.*://')"
until "$REAL_PSQL" -h "$LOCAL_PGHOST" -p "$PORT" -U postgres -d postgres -Atqc 'SELECT 1' \
  >/dev/null 2>&1; do
  sleep 0.2
done
"$REAL_PSQL" -h "$LOCAL_PGHOST" -p "$PORT" -U postgres -d postgres \
  -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE ROLE cli_login_runner LOGIN;
GRANT postgres TO cli_login_runner;
CREATE ROLE cli_login_denied LOGIN;
SQL

cat >"$FAKE_BIN/supabase" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$ISSUER_LOG"
[[ "$*" == "db dump --linked --schema public --dry-run" ]] || exit 91
cat <<EXPORTS
export PGHOST="${FAKE_PGHOST:-aws-0-ap-southeast-1.pooler.supabase.com}"
export PGPORT="${FAKE_PGPORT:-5432}"
export PGUSER="${FAKE_PGUSER:-cli_login_test.ynriuoomotxuwhuxxmhj}"
export PGPASSWORD="$SECRET"
export PGDATABASE="postgres"

pg_dump --schema-only --schema public
EXPORTS
printf '%s\n' 'DRY RUN credential issuer' >&2
EOF
chmod +x "$FAKE_BIN/supabase"

cat >"$FAKE_BIN/psql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'args=%s\n' "$*" >>"$PSQL_LOG"
printf 'ssl=%s host=%s user=%s database=%s\n' \
  "${PGSSLMODE:-}" "${PGHOST:-}" "${PGUSER:-}" "${PGDATABASE:-}" >>"$PSQL_LOG"
[[ "${FAKE_PSQL_FORCE_FAIL:-0}" != "1" ]] || exit 23
exec env \
  PGHOST="$LOCAL_PGHOST" \
  PGPORT="$LOCAL_PGPORT" \
  PGUSER="$LOCAL_PGUSER" \
  PGPASSWORD= \
  PGDATABASE="${LOCAL_DB_NAME:-postgres}" \
  PGSSLMODE=disable \
  "$REAL_PSQL" "$@"
EOF
chmod +x "$FAKE_BIN/psql"

export PATH="$FAKE_BIN:$PATH"
export ISSUER_LOG PSQL_LOG SECRET REAL_PSQL
export LOCAL_PGHOST LOCAL_PGPORT="$PORT" LOCAL_PGUSER=cli_login_runner

run_linked() {
  local sql_file="$1"
  local label="$2"
  bash -c 'source "$1"; run_linked_psql_file "$2" "$3"' \
    runner "$DEPLOY_SCRIPT" "$sql_file" "$label"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || {
    printf 'unexpected output contained %s\n' "$needle" >&2
    exit 1
  }
}

SUCCESS_SQL="$TMP_DIR/success.sql"
cat >"$SUCCESS_SQL" <<'SQL'
DO $$
BEGIN
  IF current_user <> 'postgres' OR session_user <> 'cli_login_runner' THEN
    RAISE EXCEPTION 'runner file did not inherit activated postgres role';
  END IF;
END;
$$;
CREATE TABLE runner_success (id integer PRIMARY KEY);
INSERT INTO runner_success VALUES (1);
SQL

success_output="$(run_linked "$SUCCESS_SQL" 'runner success' 2>&1)"
[[ "$success_output" == *'PASS: runner success'* ]]
"$REAL_PSQL" -h "$LOCAL_PGHOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT count(*) FROM runner_success" | grep -qx 1
grep -qx 'db dump --linked --schema public --dry-run' "$ISSUER_LOG"
grep -q 'args=-X --no-psqlrc -v ON_ERROR_STOP=1 --single-transaction --command SET ROLE postgres;' "$PSQL_LOG"
grep -q -- '--command DO \$pos_role_check\$' "$PSQL_LOG"
grep -q -- '--file .*success.sql' "$PSQL_LOG"
grep -q 'ssl=require host=aws-0-ap-southeast-1.pooler.supabase.com user=cli_login_test.ynriuoomotxuwhuxxmhj database=postgres' "$PSQL_LOG"
assert_not_contains "$success_output" "$SECRET"

ROLE_REFUSAL_SQL="$TMP_DIR/role_refusal.sql"
cat >"$ROLE_REFUSAL_SQL" <<'SQL'
CREATE TABLE runner_role_refusal_must_not_run (id integer PRIMARY KEY);
SQL

set +e
role_refusal_output="$(LOCAL_PGUSER=cli_login_denied \
  run_linked "$ROLE_REFUSAL_SQL" 'role activation refusal' 2>&1)"
role_refusal_status=$?
set -e
[[ "$role_refusal_status" -ne 0 ]]
[[ "$role_refusal_output" == *'permission denied to set role "postgres"'* ]]
assert_not_contains "$role_refusal_output" 'PASS: role activation refusal'
assert_not_contains "$role_refusal_output" "$SECRET"
"$REAL_PSQL" -h "$LOCAL_PGHOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT to_regclass('public.runner_role_refusal_must_not_run') IS NULL" | grep -qx t

set +e
unbound_user_output="$(FAKE_PGUSER=postgres \
  run_linked "$ROLE_REFUSAL_SQL" 'unbound credential refusal' 2>&1)"
unbound_user_status=$?
set -e
[[ "$unbound_user_status" -ne 0 ]]
[[ "$unbound_user_output" == *'not a ref-bound temporary cli_login role'* ]]
assert_not_contains "$unbound_user_output" 'PASS: unbound credential refusal'
assert_not_contains "$unbound_user_output" "$SECRET"
"$REAL_PSQL" -h "$LOCAL_PGHOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT to_regclass('public.runner_role_refusal_must_not_run') IS NULL" | grep -qx t

FAIL_SQL="$TMP_DIR/fail.sql"
cat >"$FAIL_SQL" <<'SQL'
CREATE TABLE runner_mid_file_rollback (id integer PRIMARY KEY);
INSERT INTO runner_mid_file_rollback VALUES (1);
DO $$ BEGIN RAISE EXCEPTION 'intentional assertion failure'; END $$;
INSERT INTO runner_mid_file_rollback VALUES (2);
SQL

set +e
failure_output="$(run_linked "$FAIL_SQL" 'runner assertion' 2>&1)"
failure_status=$?
set -e
[[ "$failure_status" -ne 0 ]]
assert_not_contains "$failure_output" 'PASS: runner assertion'
assert_not_contains "$failure_output" "$SECRET"
"$REAL_PSQL" -h "$LOCAL_PGHOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT to_regclass('public.runner_mid_file_rollback') IS NULL" | grep -qx t

set +e
wrong_target_output="$(FAKE_PGHOST='db.wrongprojectref.supabase.co' \
  run_linked "$SUCCESS_SQL" 'wrong target' 2>&1)"
wrong_target_status=$?
set -e
[[ "$wrong_target_status" -ne 0 ]]
[[ "$wrong_target_output" == *'not an allowed POS direct or pooler host'* ]]
assert_not_contains "$wrong_target_output" 'PASS: wrong target'
assert_not_contains "$wrong_target_output" "$SECRET"

WRONG_REPO="$TMP_DIR/wrong-repo"
mkdir -p "$WRONG_REPO/scripts" "$WRONG_REPO/supabase/.temp"
cp "$DEPLOY_SCRIPT" "$WRONG_REPO/scripts/deploy_pos_production.sh"
printf '%s\n' wrongprojectref >"$WRONG_REPO/supabase/.temp/project-ref"
set +e
wrong_ref_output="$(bash -c '
  source "$1"
  DEPLOY_MODE=prebuilt
  SKIP_CHECKS=1
  SKIP_AUTH_CHECK=1
  SKIP_LOGIN_SMOKE=1
  SKIP_DB=1
  SKIP_VERCEL=1
  preflight
' wrong-ref "$WRONG_REPO/scripts/deploy_pos_production.sh" 2>&1)"
wrong_ref_status=$?
set -e
[[ "$wrong_ref_status" -ne 0 ]]
[[ "$wrong_ref_output" == *'Linked Supabase project is not POS production'* ]]

set +e
forced_failure_output="$(FAKE_PSQL_FORCE_FAIL=1 run_linked "$SUCCESS_SQL" 'forced psql failure' 2>&1)"
forced_failure_status=$?
set -e
[[ "$forced_failure_status" -ne 0 ]]
assert_not_contains "$forced_failure_output" 'PASS: forced psql failure'
assert_not_contains "$forced_failure_output" "$SECRET"

SETUP_SQL="$ROOT_DIR/test/fixtures/legal_entity_deploy_local_setup.sql"
CAPTURE_SQL="$ROOT_DIR/test/fixtures/legal_entity_deploy_capture_backups.sql"
ASSERT_REPLAY_SQL="$ROOT_DIR/test/fixtures/legal_entity_deploy_assert_replay.sql"
ASSERT_ROLLBACK_SQL="$ROOT_DIR/test/fixtures/legal_entity_deploy_assert_rollback.sql"
PREFLIGHT_SQL="$ROOT_DIR/scripts/preflight_legal_entity_brand_store_hierarchy.sql"
MIGRATION_SQL="$ROOT_DIR/supabase/migrations/20260711090000_legal_entity_brand_store_hierarchy.sql"
VERIFY_SQL="$ROOT_DIR/scripts/verify_legal_entity_brand_store_hierarchy.sql"
ROLLBACK_SQL="$ROOT_DIR/scripts/rollback_legal_entity_brand_store_hierarchy.sql"

"$REAL_CREATEDB" -h "$LOCAL_PGHOST" -p "$PORT" -U postgres legal_entity_smoke
LOCAL_DB_NAME=legal_entity_smoke run_linked "$SETUP_SQL" 'local fixture setup' >/dev/null
LOCAL_DB_NAME=legal_entity_smoke run_linked "$PREFLIGHT_SQL" 'hierarchy preflight smoke' >/dev/null
LOCAL_DB_NAME=legal_entity_smoke run_linked "$MIGRATION_SQL" 'hierarchy migration smoke' >/dev/null
LOCAL_DB_NAME=legal_entity_smoke run_linked "$VERIFY_SQL" 'hierarchy verify smoke' >/dev/null
LOCAL_DB_NAME=legal_entity_smoke run_linked "$CAPTURE_SQL" 'capture immutable backups' >/dev/null
LOCAL_DB_NAME=legal_entity_smoke run_linked "$MIGRATION_SQL" 'hierarchy replay smoke' >/dev/null
LOCAL_DB_NAME=legal_entity_smoke run_linked "$ASSERT_REPLAY_SQL" 'replay immutability assertion' >/dev/null

"$REAL_CREATEDB" -h "$LOCAL_PGHOST" -p "$PORT" -U postgres \
  -T legal_entity_smoke missing_backup_smoke
"$REAL_PSQL" -h "$LOCAL_PGHOST" -p "$PORT" -U postgres \
  -d missing_backup_smoke -v ON_ERROR_STOP=1 \
  -c 'DROP TABLE public.hierarchy_20260711090000_object_backup' >/dev/null
set +e
missing_backup_output="$(LOCAL_DB_NAME=missing_backup_smoke \
  run_linked "$VERIFY_SQL" 'missing backup verification' 2>&1)"
missing_backup_status=$?
set -e
[[ "$missing_backup_status" -ne 0 ]]
[[ "$missing_backup_output" == *'HIERARCHY_VERIFY_MIGRATION_ARTIFACT_MISSING'* ]]
assert_not_contains "$missing_backup_output" 'PASS: missing backup verification'

LOCAL_DB_NAME=legal_entity_smoke run_linked "$ROLLBACK_SQL" 'hierarchy rollback smoke' >/dev/null
LOCAL_DB_NAME=legal_entity_smoke run_linked "$ASSERT_ROLLBACK_SQL" 'exact rollback assertion' >/dev/null

printf 'PASS: POS linked psql runner and legal-entity local database smoke\n'
