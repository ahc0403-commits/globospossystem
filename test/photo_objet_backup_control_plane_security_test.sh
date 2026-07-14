#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSQL="$(command -v psql)"
CONTAINER="globos-photo-backup-security-test-$$"
HOST=127.0.0.1
TMP_DIR="$(mktemp -d)"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

docker run --detach --rm \
  --name "$CONTAINER" \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  --publish 127.0.0.1::5432 \
  postgres:15 >/dev/null
PORT="$(docker port "$CONTAINER" 5432/tcp | sed 's/.*://')"
until "$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc 'SELECT 1' \
  >/dev/null 2>&1; do
  sleep 0.2
done

run_sql() {
  "$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres \
    -X --no-psqlrc -v ON_ERROR_STOP=1 --single-transaction --file "$1"
}

query() {
  "$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres \
    -X --no-psqlrc -v ON_ERROR_STOP=1 -Atqc "$1"
}

run_sql "$ROOT_DIR/test/fixtures/photo_objet_interval_rebuild_setup.sql" >/dev/null
run_sql "$ROOT_DIR/supabase/migrations/20260712190000_photo_objet_interval_ledger.sql" \
  >/dev/null

# The amended source migration must defeat broad default ACLs on fresh replay.
query "
  SELECT count(*)
  FROM pg_class
  WHERE relnamespace = 'public'::regnamespace
    AND relname LIKE 'photo_interval_20260712190000_%'
    AND relrowsecurity
    AND relforcerowsecurity" | grep -qx 5
query "
  SELECT count(*)
  FROM pg_class c
  WHERE c.relnamespace = 'public'::regnamespace
    AND c.relname LIKE 'photo_interval_20260712190000_%'
    AND c.relkind IN ('r', 'p')
    AND NOT has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')" \
  | grep -qx 5

# Reproduce the vulnerable already-deployed catalog before the repair exists.
query "
  ALTER TABLE public.photo_interval_20260712190000_jobs_backup DISABLE ROW LEVEL SECURITY;
  ALTER TABLE public.photo_interval_20260712190000_jobs_backup NO FORCE ROW LEVEL SECURITY;
  ALTER TABLE public.photo_interval_20260712190000_raw_backup DISABLE ROW LEVEL SECURITY;
  ALTER TABLE public.photo_interval_20260712190000_raw_backup NO FORCE ROW LEVEL SECURITY;
  ALTER TABLE public.photo_interval_20260712190000_runs_backup DISABLE ROW LEVEL SECURITY;
  ALTER TABLE public.photo_interval_20260712190000_runs_backup NO FORCE ROW LEVEL SECURITY;
  ALTER TABLE public.photo_interval_20260712190000_sales_backup DISABLE ROW LEVEL SECURITY;
  ALTER TABLE public.photo_interval_20260712190000_sales_backup NO FORCE ROW LEVEL SECURITY;
  ALTER TABLE public.photo_interval_20260712190000_state DISABLE ROW LEVEL SECURITY;
  ALTER TABLE public.photo_interval_20260712190000_state NO FORCE ROW LEVEL SECURITY;
  GRANT ALL ON TABLE
    public.photo_interval_20260712190000_jobs_backup,
    public.photo_interval_20260712190000_raw_backup,
    public.photo_interval_20260712190000_runs_backup,
    public.photo_interval_20260712190000_sales_backup,
    public.photo_interval_20260712190000_state
  TO PUBLIC, anon, authenticated, service_role;"

query "SELECT has_table_privilege(
  'anon', 'public.photo_interval_20260712190000_jobs_backup', 'SELECT')" \
  | grep -qx t

# A missing sixth target must fail before changing any of the first five.
if run_sql "$ROOT_DIR/scripts/preflight_photo_objet_backup_control_plane_security.sql" \
  >"$TMP_DIR/missing-preflight.log" 2>&1; then
  printf 'expected missing-target preflight failure\n' >&2
  exit 1
fi
grep -q 'PHOTO_OBJET_BACKUP_SECURITY_TARGET_MISSING_OR_INVALID' \
  "$TMP_DIR/missing-preflight.log"
if run_sql "$ROOT_DIR/supabase/migrations/20260715010000_photo_objet_backup_control_plane_security.sql" \
  >"$TMP_DIR/missing-migration.log" 2>&1; then
  printf 'expected missing-target migration failure\n' >&2
  exit 1
fi
grep -q 'PHOTO_OBJET_BACKUP_SECURITY_TARGET_MISSING_OR_INVALID' \
  "$TMP_DIR/missing-migration.log"
query "SELECT relrowsecurity
  FROM pg_class
  WHERE oid = 'public.photo_interval_20260712190000_jobs_backup'::regclass" \
  | grep -qx f
query "SELECT has_table_privilege(
  'anon', 'public.photo_interval_20260712190000_jobs_backup', 'SELECT')" \
  | grep -qx t

query "CREATE TABLE public.photo_slot_20260713120000_state (
  migration_id text PRIMARY KEY,
  prior_health_function_definition text
);"
query "SELECT has_table_privilege(
  'anon', 'public.photo_slot_20260713120000_state', 'SELECT')" \
  | grep -qx t

run_sql "$ROOT_DIR/scripts/preflight_photo_objet_backup_control_plane_security.sql" \
  | grep -q 'PHOTO_OBJET_BACKUP_SECURITY_PREFLIGHT_OK'
for _ in 1 2; do
  run_sql "$ROOT_DIR/supabase/migrations/20260715010000_photo_objet_backup_control_plane_security.sql" \
    >/dev/null
done
run_sql "$ROOT_DIR/scripts/verify_photo_objet_backup_control_plane_security.sql" \
  | grep -q 'PHOTO_OBJET_BACKUP_SECURITY_VERIFY_OK'

for role in anon authenticated service_role; do
  if query "SET ROLE $role;
    SELECT count(*) FROM public.photo_interval_20260712190000_jobs_backup;" \
    >"$TMP_DIR/$role-access.log" 2>&1; then
    printf 'expected %s access denial\n' "$role" >&2
    exit 1
  fi
  grep -q 'permission denied' "$TMP_DIR/$role-access.log"
done

# The database owner can still authenticate and use the immutable evidence.
query "SELECT count(*) FROM public.photo_interval_20260712190000_jobs_backup" \
  | grep -qx 1
run_sql "$ROOT_DIR/scripts/rollback_photo_objet_interval_rebuild.sql" \
  | grep -q 'PHOTO_INTERVAL_ROLLBACK_OK'
query "SELECT count(*)
  FROM pg_class
  WHERE relnamespace = 'public'::regnamespace
    AND relname LIKE 'photo_interval_20260712190000_%'" | grep -qx 0
query "SELECT relrowsecurity AND relforcerowsecurity
  FROM pg_class
  WHERE oid = 'public.photo_slot_20260713120000_state'::regclass" | grep -qx t

printf 'PASS: Photo Objet backup control-plane security, replay, and owner rollback\n'
