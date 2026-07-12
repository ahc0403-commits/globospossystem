#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSQL="$(command -v psql)"
CONTAINER="globos-photo-interval-test-$$"
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

run_sql "$ROOT_DIR/test/fixtures/photo_objet_interval_rebuild_setup.sql" >/dev/null

"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "UPDATE public.meinvoice_jobs SET dispatch_attempts = 1 WHERE source_system = 'photo_objet_moers'"
if run_sql "$ROOT_DIR/supabase/migrations/20260712190000_photo_objet_interval_ledger.sql" \
  >"$TMP_DIR/negative.log" 2>&1; then
  printf 'expected dispatched-job preflight failure\n' >&2
  exit 1
fi
grep -q 'PHOTO_INTERVAL_PREFLIGHT_DISPATCHED_JOBS' "$TMP_DIR/negative.log"
"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "UPDATE public.meinvoice_jobs SET dispatch_attempts = 0 WHERE source_system = 'photo_objet_moers'"

run_sql "$ROOT_DIR/supabase/migrations/20260712190000_photo_objet_interval_ledger.sql" >/dev/null

"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE OR REPLACE FUNCTION public.test_photo_enqueue_trigger()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.enqueue_photo_objet_meinvoice_job(NEW.id);
  RETURN NEW;
END $$;
CREATE TRIGGER test_photo_enqueue
AFTER INSERT ON public.photo_objet_sales_raw
FOR EACH ROW EXECUTE FUNCTION public.test_photo_enqueue_trigger();

INSERT INTO public.photo_objet_sales_raw (
  store_id, sale_date, device_name, device_id, sale_time_text, sold_at, amount,
  raw_type, source_hash, source_identity_version, occurrence_no,
  interval_start_at, interval_end_at
) VALUES
  ('77000000-0000-4000-8000-000000000102', DATE '2026-07-12', 'M1', 'D1',
   '2026-07-12 11:15:00', '2026-07-12 11:15:00+07', 100000, 'Sale',
   'v2-hash-1', 2, 1, '2026-07-12 11:00:00+07', '2026-07-12 12:00:00+07'),
  ('77000000-0000-4000-8000-000000000102', DATE '2026-07-12', 'M1', 'D1',
   '2026-07-12 11:15:00', '2026-07-12 11:15:00+07', 100000, 'Sale',
   'v2-hash-2', 2, 2, '2026-07-12 11:00:00+07', '2026-07-12 12:00:00+07');

INSERT INTO public.photo_objet_sales (
  store_id, sale_date, device_name, device_id, gross_sales, transaction_count
) VALUES (
  '77000000-0000-4000-8000-000000000102', DATE '2026-07-12', 'M1', 'D1', 200000, 2
);
SQL

run_sql "$ROOT_DIR/supabase/migrations/20260712190000_photo_objet_interval_ledger.sql" >/dev/null
run_sql "$ROOT_DIR/scripts/verify_photo_objet_interval_rebuild.sql" >/dev/null

"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT count(*) FROM public.photo_objet_sales_raw" | grep -qx 2
"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT count(*) FROM public.meinvoice_jobs WHERE source_system='photo_objet_moers' AND status='pending_manual_config'" | grep -qx 2
"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT count(*) FROM public.photo_objet_sales WHERE store_id='77000000-0000-4000-8000-000000000108' AND sale_date='2026-07-12'" | grep -qx 1

run_sql "$ROOT_DIR/scripts/rollback_photo_objet_interval_rebuild.sql" >/dev/null
"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT count(*) FROM public.photo_objet_sales_raw WHERE sold_at IS NULL" | grep -qx 1
"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT count(*) FROM public.meinvoice_jobs WHERE source_system='photo_objet_moers'" | grep -qx 1
"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT count(*) FROM public.photo_objet_sales" | grep -qx 3
"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT position('ORIGINAL_ENQUEUE_FUNCTION' in pg_get_functiondef('public.enqueue_photo_objet_meinvoice_job(uuid)'::regprocedure)) > 0" | grep -qx t
"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT count(*) FROM public.system_config WHERE key='photo_objet_meinvoice_dispatch_enabled'" | grep -qx 0
"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name IN ('photo_objet_sales_raw','photo_objet_sales_pull_runs') AND column_name IN ('source_identity_version','occurrence_no','interval_start_at','interval_end_at','run_source','slot_id','slot_date_hcm','slot_time_hcm')" | grep -qx 0
"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT count(*) FROM pg_class WHERE relnamespace='public'::regnamespace AND relname LIKE 'photo_interval_20260712190000_%'" | grep -qx 0

run_sql "$ROOT_DIR/supabase/migrations/20260712190000_photo_objet_interval_ledger.sql" >/dev/null
"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT count(*) FROM public.photo_interval_20260712190000_raw_backup" | grep -qx 1
"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT count(*) FROM public.photo_interval_20260712190000_jobs_backup" | grep -qx 1
"$PSQL" -h "$HOST" -p "$PORT" -U postgres -d postgres -Atqc \
  "SELECT count(*) FROM public.photo_objet_sales_raw" | grep -qx 0

printf 'PASS: Photo Objet interval migration, dispatch gate, replay, and rollback\n'
