#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_PSQL="$(command -v psql)"
CONTAINER="globos-meinvoice-replay-$$"
HOST=127.0.0.1
DB=meinvoice_replay
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
until "$REAL_PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc 'SELECT 1' \
  >/dev/null 2>&1; do
  sleep 0.2
done
createdb -h "$HOST" -p "$PORT" -U postgres "$DB"

run_file() {
  local file="$1"
  PGHOST="$HOST" PGPORT="$PORT" PGUSER=postgres PGDATABASE="$DB" \
    "$REAL_PSQL" -X --no-psqlrc -v ON_ERROR_STOP=1 \
      --single-transaction --file "$file" >/dev/null
}

SETUP="$ROOT_DIR/test/fixtures/meinvoice_main_migration_replay_setup.sql"
MIGRATIONS=(
  "$ROOT_DIR/supabase/migrations/20260630000000_wetax_shutdown_meinvoice_foundation.sql"
  "$ROOT_DIR/supabase/migrations/20260630001000_meinvoice_buyer_fields.sql"
  "$ROOT_DIR/supabase/migrations/20260630002000_meinvoice_dispatcher_foundation.sql"
  "$ROOT_DIR/supabase/migrations/20260630003000_meinvoice_admin_ops.sql"
  "$ROOT_DIR/supabase/migrations/20260630004000_meinvoice_readiness.sql"
  "$ROOT_DIR/supabase/migrations/20260630005000_meinvoice_config_admin.sql"
  "$ROOT_DIR/supabase/migrations/20260630006000_meinvoice_ready_queue_admin.sql"
  "$ROOT_DIR/supabase/migrations/20260711090000_legal_entity_brand_store_hierarchy.sql"
  "$ROOT_DIR/supabase/migrations/20260711190000_meinvoice_portal_defaults.sql"
)

run_file "$SETUP"
for migration in "${MIGRATIONS[@]}"; do
  run_file "$migration"
done

VERIFY="$TMP_DIR/verify.sql"
cat >"$VERIFY" <<'SQL'
DO $verify$
BEGIN
  IF (SELECT column_default FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = 'meinvoice_tax_entity_config'
        AND column_name = 'auth_base_url') NOT LIKE
       '%developer.misa.vn/apis/itg/meinvoice/invoice%' THEN
    RAISE EXCEPTION 'MEINVOICE_REPLAY_PORTAL_AUTH_DEFAULT_MISSING';
  END IF;
  IF to_regclass('public.tax_entity_brands') IS NULL
     OR to_regclass('public.meinvoice_token_cache') IS NULL
     OR to_regprocedure('public.admin_release_meinvoice_ready_jobs(uuid,integer)') IS NULL THEN
    RAISE EXCEPTION 'MEINVOICE_REPLAY_REQUIRED_OBJECT_MISSING';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'meinvoice_jobs'
      AND column_name = 'dispatch_claim_id'
  ) THEN
    RAISE EXCEPTION 'MEINVOICE_REPLAY_CLAIM_COLUMN_MISSING';
  END IF;
END;
$verify$;
SQL
run_file "$VERIFY"

# Replay-safe migrations must retain the same objects and portal defaults.
for migration in "${MIGRATIONS[@]}"; do
  run_file "$migration"
done
run_file "$VERIFY"

# A middle-statement failure must roll back the complete file and leave no residue.
FAIL="$TMP_DIR/fail.sql"
cat >"$FAIL" <<'SQL'
CREATE TABLE public.meinvoice_replay_must_rollback (id int PRIMARY KEY);
INSERT INTO public.meinvoice_replay_must_rollback VALUES (1);
DO $$ BEGIN RAISE EXCEPTION 'MEINVOICE_REPLAY_EXPECTED_FAILURE'; END $$;
SQL
set +e
failure_output="$(run_file "$FAIL" 2>&1)"
failure_status=$?
set -e
[[ "$failure_status" -ne 0 ]]
[[ "$failure_output" == *MEINVOICE_REPLAY_EXPECTED_FAILURE* ]]
PGHOST="$HOST" PGPORT="$PORT" PGUSER=postgres PGDATABASE="$DB" \
  "$REAL_PSQL" -X --no-psqlrc -Atqc \
  "SELECT to_regclass('public.meinvoice_replay_must_rollback') IS NULL" |
  grep -qx t

printf 'PASS: clean main MISA migration replay and fail-fast rollback\n'
