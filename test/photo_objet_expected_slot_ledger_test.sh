#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_PSQL="$(command -v psql)"
REAL_CREATEDB="$(command -v createdb)"
CONTAINER="globos-photo-slot-ledger-test-$$"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run --detach --rm \
  --name "$CONTAINER" \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  --publish 127.0.0.1::5432 \
  postgres:15 >/dev/null
PORT="$(docker port "$CONTAINER" 5432/tcp | sed 's/.*://')"
until "$REAL_PSQL" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -Atqc 'SELECT 1' \
  >/dev/null 2>&1; do
  sleep 0.2
done

psql_db() {
  local database="$1"
  shift
  "$REAL_PSQL" -h 127.0.0.1 -p "$PORT" -U postgres -d "$database" \
    -X --no-psqlrc -v ON_ERROR_STOP=1 "$@"
}

psql_test() {
  psql_db postgres "$@"
}

create_fixture_db() {
  "$REAL_CREATEDB" -h 127.0.0.1 -p "$PORT" -U postgres \
    --template postgres "$1"
}

psql_test >/dev/null <<'SQL'
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role BYPASSRLS;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO service_role;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA auth;

CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;

CREATE TABLE public.restaurants (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  brand_id uuid,
  is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE public.user_store_access (user_id uuid NOT NULL, store_id uuid NOT NULL);
CREATE FUNCTION public.user_accessible_stores(uid uuid)
RETURNS TABLE(store_id uuid)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  SELECT usa.store_id FROM public.user_store_access usa WHERE usa.user_id = uid
$$;
CREATE FUNCTION public.is_super_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT false $$;
CREATE VIEW public.v_office_eligible_stores AS
SELECT id AS store_id FROM public.restaurants WHERE is_active = true;

CREATE TABLE public.photo_objet_sales_pull_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  target_date date NOT NULL,
  run_source text,
  slot_id text,
  slot_date_hcm date,
  slot_time_hcm time,
  interval_start_at timestamptz,
  interval_end_at timestamptz,
  status text NOT NULL,
  aggregate_rows integer,
  finished_at timestamptz,
  error_message text
);
CREATE TABLE public.photo_objet_sales_raw (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  source_hash text NOT NULL UNIQUE
);
CREATE TABLE public.photo_objet_sales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id)
);
CREATE FUNCTION public.photo_objet_collection_health_at(
  p_observed_at timestamptz DEFAULT now()
)
RETURNS TABLE (
  store_id uuid, target_date date, expected_slots integer, due_slots integer,
  successful_slots integer, failed_slots integer, missing_slots integer,
  missing_slot_times text[], failed_slot_times text[],
  latest_successful_slot timestamptz, next_expected_slot timestamptz,
  last_finished_at timestamptz, observed_at timestamptz, status text,
  is_healthy boolean
)
LANGUAGE sql STABLE AS $$
  SELECT null::uuid, null::date, 0, 0, 0, 0, 0, ARRAY[]::text[],
    ARRAY[]::text[], null::timestamptz, null::timestamptz, null::timestamptz,
    p_observed_at, 'legacy'::text, false WHERE false
$$;
CREATE VIEW public.v_photo_objet_collection_health AS
SELECT * FROM public.photo_objet_collection_health_at(now());

GRANT USAGE ON SCHEMA public, auth TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.user_accessible_stores(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.is_super_admin() TO authenticated, service_role;
GRANT SELECT ON public.restaurants, public.v_office_eligible_stores TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON public.photo_objet_sales_pull_runs TO service_role;

INSERT INTO public.restaurants (id, name, brand_id, is_active)
SELECT
  ('77000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
  'LOAD STORE ' || i,
  '88000000-0000-0000-0000-000000000001'::uuid,
  true
FROM generate_series(1, 6) i;
SQL

create_fixture_db photo_slot_existing_column
create_fixture_db photo_slot_existing_constraint
create_fixture_db photo_slot_missing_health_function
create_fixture_db photo_slot_bad_type
create_fixture_db photo_slot_bad_constraint

psql_test --file "$ROOT_DIR/scripts/preflight_photo_objet_expected_slot_ledger.sql" \
  | grep -q 'PHOTO_OBJET_EXPECTED_SLOT_PREFLIGHT_PASS'

export PHOTO_OBJET_MONITORING_EFFECTIVE_FROM='2026-07-14 00:00:00+07'
export PHOTO_OBJET_BIENHOA_STORE_ID='77000000-0000-4000-8000-000000000001'
export PHOTO_OBJET_DIAN_STORE_ID='77000000-0000-4000-8000-000000000002'
export PHOTO_OBJET_LONGTHANH_STORE_ID='77000000-0000-4000-8000-000000000003'
export PHOTO_OBJET_THAODIEN_STORE_ID='77000000-0000-4000-8000-000000000004'
export PHOTO_OBJET_QUANGTRUNG_STORE_ID='77000000-0000-4000-8000-000000000005'
export PHOTO_OBJET_NOWZONE_STORE_ID='77000000-0000-4000-8000-000000000006'

apply_fixture() {
  local database="$1"
  psql_db "$database" --single-transaction \
    -v "photo_policy_effective_from=$PHOTO_OBJET_MONITORING_EFFECTIVE_FROM" \
    -v "photo_store_bienhoa=$PHOTO_OBJET_BIENHOA_STORE_ID" \
    -v "photo_store_dian=$PHOTO_OBJET_DIAN_STORE_ID" \
    -v "photo_store_longthanh=$PHOTO_OBJET_LONGTHANH_STORE_ID" \
    -v "photo_store_thaodien=$PHOTO_OBJET_THAODIEN_STORE_ID" \
    -v "photo_store_quangtrung=$PHOTO_OBJET_QUANGTRUNG_STORE_ID" \
    -v "photo_store_nowzone=$PHOTO_OBJET_NOWZONE_STORE_ID" \
    --file "$ROOT_DIR/scripts/apply_photo_objet_expected_slot_ledger.sql"
}

catalog_fingerprint() {
  local database="$1"
  psql_db "$database" -Atqc "
    SELECT concat_ws('|',
      format_type(a.atttypid, a.atttypmod),
      a.attnotnull::text,
      coalesce(pg_get_expr(d.adbin, d.adrelid), '<NULL>'),
      coalesce(col_description(a.attrelid, a.attnum), '<NULL>'),
      coalesce((
        SELECT pg_get_constraintdef(c.oid, true)
        FROM pg_constraint c
        WHERE c.conrelid = a.attrelid
          AND c.conname = 'photo_objet_pull_run_interval_rows_check'
      ), '<NULL>')
    )
    FROM pg_attribute a
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE a.attrelid = 'public.photo_objet_sales_pull_runs'::regclass
      AND a.attname = 'interval_rows' AND NOT a.attisdropped"
}

for _ in 1 2; do
  psql_test --single-transaction \
    -v "photo_policy_effective_from=$PHOTO_OBJET_MONITORING_EFFECTIVE_FROM" \
    -v "photo_store_bienhoa=$PHOTO_OBJET_BIENHOA_STORE_ID" \
    -v "photo_store_dian=$PHOTO_OBJET_DIAN_STORE_ID" \
    -v "photo_store_longthanh=$PHOTO_OBJET_LONGTHANH_STORE_ID" \
    -v "photo_store_thaodien=$PHOTO_OBJET_THAODIEN_STORE_ID" \
    -v "photo_store_quangtrung=$PHOTO_OBJET_QUANGTRUNG_STORE_ID" \
    -v "photo_store_nowzone=$PHOTO_OBJET_NOWZONE_STORE_ID" \
    --file "$ROOT_DIR/scripts/apply_photo_objet_expected_slot_ledger.sql" \
    >/dev/null
done

# A stale hourly policy must stop before any migration replay can claim success.
psql_test -c "
  UPDATE public.photo_objet_monitoring_policies
  SET grace_minutes = 15
  WHERE store_id = '$PHOTO_OBJET_BIENHOA_STORE_ID'" >/dev/null
set +e
schedule_mismatch_output="$(psql_test \
  --file "$ROOT_DIR/scripts/preflight_photo_objet_expected_slot_ledger.sql" 2>&1)"
schedule_mismatch_status=$?
set -e
[[ "$schedule_mismatch_status" -ne 0 ]]
[[ "$schedule_mismatch_output" == *'PHOTO_SLOT_PREFLIGHT_SCHEDULE_POLICY_MISMATCH'* ]]
[[ "$schedule_mismatch_output" != *'PHOTO_OBJET_EXPECTED_SLOT_PREFLIGHT_PASS'* ]]
psql_test -c "
  UPDATE public.photo_objet_monitoring_policies
  SET grace_minutes = 90
  WHERE store_id = '$PHOTO_OBJET_BIENHOA_STORE_ID'" >/dev/null

psql_test >/dev/null <<'SQL'
DO $$
BEGIN
  IF has_table_privilege('service_role', 'public.photo_slot_20260713120000_state', 'SELECT')
     OR has_table_privilege('service_role', 'public.photo_slot_20260713120000_state', 'INSERT')
     OR has_table_privilege('service_role', 'public.photo_slot_20260713120000_state', 'UPDATE')
     OR has_table_privilege('service_role', 'public.photo_slot_20260713120000_state', 'DELETE')
     OR has_table_privilege('service_role', 'public.photo_objet_monitoring_policies', 'INSERT')
     OR has_table_privilege('service_role', 'public.photo_objet_monitoring_policies', 'UPDATE')
     OR has_table_privilege('service_role', 'public.photo_objet_monitoring_policies', 'DELETE')
     OR has_table_privilege('service_role', 'public.photo_objet_expected_slots', 'INSERT')
     OR has_table_privilege('service_role', 'public.photo_objet_expected_slots', 'UPDATE')
     OR has_table_privilege('service_role', 'public.photo_objet_expected_slots', 'DELETE') THEN
    RAISE EXCEPTION 'PHOTO_SLOT_SERVICE_ROLE_DIRECT_WRITE_ALLOWED';
  END IF;
END $$;
SQL

psql_test >/dev/null <<'SQL'
INSERT INTO public.restaurants (id, name, brand_id, is_active)
SELECT
  ('77000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
  'LOAD STORE ' || i,
  '88000000-0000-0000-0000-000000000001'::uuid,
  true
FROM generate_series(1, 60) i
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.photo_objet_monitoring_policies (
  store_id, effective_from, timezone, schedule_version,
  grace_minutes, final_slot_grace_minutes, is_enabled
)
SELECT id, '2026-07-14 00:00:00+07', 'Asia/Ho_Chi_Minh',
  'hcm-two-hour-v1', 90, 90, true
FROM public.restaurants
ON CONFLICT (store_id, effective_from) DO NOTHING;

DO $$
DECLARE v_inserted integer;
BEGIN
  PERFORM public.photo_objet_ensure_expected_slots('2026-07-14', '2026-07-14');
  SELECT count(*) INTO v_inserted
  FROM public.photo_objet_expected_slots
  WHERE slot_date_hcm = '2026-07-14';
  IF v_inserted <> 420 THEN
    RAISE EXCEPTION 'PHOTO_SLOT_LOAD_COUNT_FAILED: %', v_inserted;
  END IF;
  IF public.photo_objet_ensure_expected_slots('2026-07-14', '2026-07-14') <> 0 THEN
    RAISE EXCEPTION 'PHOTO_SLOT_REPLAY_NOT_IDEMPOTENT';
  END IF;
END $$;

-- One policy missing one materialized slot must fail closed even while other
-- stores have complete ledgers. Re-materialization repairs the control plane.
DELETE FROM public.photo_objet_expected_slots
WHERE store_id = '77000000-0000-4000-8000-000000000060'
  AND slot_date_hcm = '2026-07-14'
  AND slot_time_hcm = TIME '23:00';
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.photo_objet_expected_slot_health_at(
      '2026-07-14 10:20:00+07', 1
    )
    WHERE store_id = '77000000-0000-4000-8000-000000000060'
      AND coverage_missing_slots = 1
      AND status = 'audit_infra_failed'
      AND 'AUDIT_INFRA_FAILED' = ANY(failure_classes)
  ) THEN
    RAISE EXCEPTION 'PHOTO_SLOT_PARTIAL_POLICY_COVERAGE_NOT_FAILED_CLOSED';
  END IF;
  IF public.photo_objet_ensure_expected_slots('2026-07-14', '2026-07-14') <> 1 THEN
    RAISE EXCEPTION 'PHOTO_SLOT_PARTIAL_POLICY_COVERAGE_REPAIR_FAILED';
  END IF;
END $$;

-- A policy effective at 12:00 must never create the earlier 10:00 slot.
INSERT INTO public.restaurants (id, name, brand_id, is_active) VALUES
  ('77000000-0000-4000-8000-000000000061', 'EFFECTIVE STORE', null, true),
  ('77000000-0000-4000-8000-000000000062', 'INACTIVE STORE', null, false);
INSERT INTO public.photo_objet_monitoring_policies (
  store_id, effective_from, timezone, schedule_version, is_enabled
) VALUES
  ('77000000-0000-4000-8000-000000000061', '2026-07-14 12:00:00+07',
   'Asia/Ho_Chi_Minh', 'hcm-two-hour-v1', true),
  ('77000000-0000-4000-8000-000000000062', '2026-07-14 00:00:00+07',
   'Asia/Ho_Chi_Minh', 'hcm-two-hour-v1', true);
SELECT public.photo_objet_ensure_expected_slots('2026-07-14', '2026-07-14');

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.photo_objet_expected_slots
    WHERE store_id = '77000000-0000-4000-8000-000000000061'
      AND slot_time_hcm = TIME '10:00'
  ) THEN RAISE EXCEPTION 'PHOTO_SLOT_POLICY_EFFECTIVE_DATE_FAILED'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.photo_objet_expected_slots
    WHERE store_id = '77000000-0000-4000-8000-000000000062'
  ) THEN RAISE EXCEPTION 'PHOTO_SLOT_INACTIVE_STORE_FAILED'; END IF;
END $$;

-- A successful 12:00 run does not cover the missing 10:00 slot.
INSERT INTO public.photo_objet_sales_pull_runs (
  store_id, target_date, run_source, slot_id, slot_date_hcm, slot_time_hcm,
  status, aggregate_rows, interval_rows, finished_at
) VALUES (
  '77000000-0000-4000-8000-000000000001', '2026-07-14', 'scheduled',
  'scheduled:2026-07-14T12:00+07:00', '2026-07-14', TIME '12:00',
  'success', 1, 1, '2026-07-14 12:05:00+07'
);
SELECT * FROM public.photo_objet_refresh_expected_slot_health(
  '2026-07-14 13:40:00+07', 1
);
DO $$
BEGIN
  IF (SELECT status FROM public.photo_objet_expected_slots
      WHERE store_id = '77000000-0000-4000-8000-000000000001'
        AND slot_time_hcm = TIME '10:00') <> 'missing' THEN
    RAISE EXCEPTION 'PHOTO_SLOT_LATER_RUN_COVERED_EARLIER_SLOT';
  END IF;
  IF (SELECT status FROM public.photo_objet_expected_slots
      WHERE store_id = '77000000-0000-4000-8000-000000000001'
        AND slot_time_hcm = TIME '12:00') <> 'collected' THEN
    RAISE EXCEPTION 'PHOTO_SLOT_TYPED_RECONCILIATION_FAILED';
  END IF;
END $$;

-- A refresh before delivery ACK must return the same pending alerts. Only a
-- successful external delivery is allowed to acknowledge them.
DO $$
DECLARE
  v_count integer;
  alert record;
BEGIN
  SELECT count(*) INTO v_count
  FROM public.photo_objet_refresh_expected_slot_health(
    '2026-07-14 13:40:00+07', 1
  );
  IF v_count <> 120 THEN
    RAISE EXCEPTION 'PHOTO_SLOT_ALERT_LOST_BEFORE_ACK: %', v_count;
  END IF;
  FOR alert IN
    SELECT * FROM public.photo_objet_refresh_expected_slot_health(
      '2026-07-14 13:40:00+07', 1
    )
  LOOP
    PERFORM public.photo_objet_ack_expected_slot_alert(
      alert.store_id, alert.slot_date_hcm, alert.slot_time_hcm,
      alert.failure_class, '2026-07-14 13:41:00+07'
    );
  END LOOP;
END $$;

-- Persistent failures remain visible after the normal lookback window and
-- after alert acknowledgement. Lookback limits healthy history, not debt.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.photo_objet_expected_slot_health_at(
      '2026-07-20 10:20:00+07', 2
    )
    WHERE target_date = '2026-07-14'
      AND missing_slots > 0
      AND 'SLOT_MISSING' = ANY(failure_classes)
  ) THEN
    RAISE EXCEPTION 'PHOTO_SLOT_PERSISTENT_FAILURE_AGED_OUT';
  END IF;
END $$;

-- A backfill with the same date is deliberately ignored by scheduler health.
INSERT INTO public.photo_objet_sales_pull_runs (
  store_id, target_date, run_source, slot_id, slot_date_hcm, slot_time_hcm,
  status, aggregate_rows, interval_rows, finished_at
) VALUES (
  '77000000-0000-4000-8000-000000000002', '2026-07-14', 'backfill',
  'backfill:2026-07-14', '2026-07-14', null, 'success', 20, 20, now()
);
SELECT * FROM public.photo_objet_refresh_expected_slot_health(
  '2026-07-14 13:40:00+07', 1
);
DO $$
BEGIN
  IF (SELECT status FROM public.photo_objet_expected_slots
      WHERE store_id = '77000000-0000-4000-8000-000000000002'
        AND slot_time_hcm = TIME '10:00') <> 'missing' THEN
    RAISE EXCEPTION 'PHOTO_SLOT_BACKFILL_REWROTE_SCHEDULER_HISTORY';
  END IF;
END $$;

-- A 52-minute scheduler delay remains healthy; the final 23:00 slot becomes
-- due only after its 90-minute grace at 00:30 HCM the next day.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.photo_objet_expected_slots
    WHERE slot_date_hcm = '2026-07-14'
      AND due_at <= scheduled_at + interval '52 minutes'
  ) THEN RAISE EXCEPTION 'PHOTO_SLOT_SCHEDULER_DELAY_GRACE_TOO_SHORT'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.photo_objet_expected_slots
    WHERE slot_date_hcm = '2026-07-14'
      AND slot_time_hcm = TIME '23:00'
      AND due_at <= '2026-07-15 00:29:59+07'
  ) THEN RAISE EXCEPTION 'PHOTO_SLOT_FINAL_EARLY_DEADLINE'; END IF;
  IF (SELECT count(*) FROM public.photo_objet_expected_slots
      WHERE store_id = '77000000-0000-4000-8000-000000000001'
        AND slot_date_hcm = '2026-07-14'
        AND slot_time_hcm = TIME '23:00'
        AND due_at = '2026-07-15 00:30:00+07') <> 1 THEN
    RAISE EXCEPTION 'PHOTO_SLOT_FINAL_DEADLINE_FAILED';
  END IF;
END $$;

-- Zero-sales is successful, duplicate completion is idempotent, and a late
-- exact-slot success recovers a previously missing slot.
INSERT INTO public.photo_objet_sales_pull_runs (
  id, store_id, target_date, run_source, slot_id, slot_date_hcm, slot_time_hcm,
  status, aggregate_rows, interval_rows, finished_at
) VALUES (
  '99000000-0000-4000-8000-000000000001',
  '77000000-0000-4000-8000-000000000003', '2026-07-14', 'scheduled',
  'scheduled:2026-07-14T10:00+07:00', '2026-07-14', TIME '10:00',
  'success', 9, 0, '2026-07-14 12:30:00+07'
);
SELECT public.photo_objet_complete_expected_slot(
  '77000000-0000-4000-8000-000000000003', '2026-07-14', TIME '10:00',
  '99000000-0000-4000-8000-000000000001', true
);
SELECT public.photo_objet_complete_expected_slot(
  '77000000-0000-4000-8000-000000000003', '2026-07-14', TIME '10:00',
  '99000000-0000-4000-8000-000000000001', true
);
DO $$
BEGIN
  IF (SELECT status FROM public.photo_objet_expected_slots
      WHERE store_id = '77000000-0000-4000-8000-000000000003'
        AND slot_time_hcm = TIME '10:00') <> 'recovered' THEN
    RAISE EXCEPTION 'PHOTO_SLOT_ZERO_SALES_RECOVERY_FAILED';
  END IF;
END $$;

-- If the collector's completion RPC is unavailable, typed run reconciliation
-- uses interval_rows rather than the nonzero daily aggregate device count.
INSERT INTO public.photo_objet_sales_pull_runs (
  store_id, target_date, run_source, slot_id, slot_date_hcm, slot_time_hcm,
  status, aggregate_rows, interval_rows, finished_at
) VALUES (
  '77000000-0000-4000-8000-000000000004', '2026-07-14', 'scheduled',
  'scheduled:2026-07-14T14:00+07:00', '2026-07-14', TIME '14:00',
  'success', 9, 0, '2026-07-14 14:25:00+07'
);
SELECT * FROM public.photo_objet_refresh_expected_slot_health(
  '2026-07-14 15:40:00+07', 1
);
DO $$
BEGIN
  IF (SELECT status FROM public.photo_objet_expected_slots
      WHERE store_id = '77000000-0000-4000-8000-000000000004'
        AND slot_time_hcm = TIME '14:00') <> 'collected_zero' THEN
    RAISE EXCEPTION 'PHOTO_SLOT_INTERVAL_ZERO_RECONCILIATION_FAILED';
  END IF;
END $$;

-- Alert claim is deduplicated by store, slot, and failure class.
DO $$
DECLARE v_count integer;
BEGIN
  SELECT count(*) INTO v_count FROM public.photo_objet_refresh_expected_slot_health(
    '2026-07-14 13:40:00+07', 1
  );
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'PHOTO_SLOT_ALERT_DEDUP_FAILED: %', v_count;
  END IF;
END $$;

INSERT INTO public.user_store_access (user_id, store_id) VALUES (
  'aa000000-0000-4000-8000-000000000001',
  '77000000-0000-4000-8000-000000000001'
);
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'aa000000-0000-4000-8000-000000000001', false);
DO $$
BEGIN
  IF (SELECT count(DISTINCT store_id) FROM public.photo_objet_expected_slots) <> 1 THEN
    RAISE EXCEPTION 'PHOTO_SLOT_RLS_SCOPE_FAILED';
  END IF;
  BEGIN
    INSERT INTO public.photo_objet_expected_slots (
      store_id, slot_date_hcm, slot_time_hcm, scheduled_at, due_at,
      monitoring_policy_id
    ) VALUES (
      '77000000-0000-4000-8000-000000000001', '2026-07-15', TIME '10:00',
      now(), now(), gen_random_uuid()
    );
    RAISE EXCEPTION 'PHOTO_SLOT_RLS_WRITE_ALLOWED';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;

UPDATE public.photo_objet_monitoring_policies
SET is_enabled = false, effective_to = '2026-07-15 00:00:00+07'
WHERE store_id = '77000000-0000-4000-8000-000000000062';

INSERT INTO public.photo_objet_sales_raw (store_id, source_hash) VALUES (
  '77000000-0000-4000-8000-000000000001', 'raw-remains-immutable'
);
SQL

psql_test --file "$ROOT_DIR/scripts/verify_photo_objet_expected_slot_ledger.sql" \
  | grep -q 'PHOTO_OBJET_EXPECTED_SLOT_VERIFY_PASS'

psql_test --single-transaction \
  --file "$ROOT_DIR/scripts/rollback_photo_objet_expected_slot_ledger.sql" \
  | grep -q 'PHOTO_OBJET_EXPECTED_SLOT_ROLLBACK_PASS'

psql_test -Atqc "SELECT count(*) FROM public.photo_objet_sales_raw WHERE source_hash='raw-remains-immutable'" \
  | grep -qx 1
psql_test -Atqc "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='photo_objet_sales_pull_runs' AND column_name='interval_rows'" \
  | grep -qx 0

psql_test --single-transaction \
  -v "photo_policy_effective_from=$PHOTO_OBJET_MONITORING_EFFECTIVE_FROM" \
  -v "photo_store_bienhoa=$PHOTO_OBJET_BIENHOA_STORE_ID" \
  -v "photo_store_dian=$PHOTO_OBJET_DIAN_STORE_ID" \
  -v "photo_store_longthanh=$PHOTO_OBJET_LONGTHANH_STORE_ID" \
  -v "photo_store_thaodien=$PHOTO_OBJET_THAODIEN_STORE_ID" \
  -v "photo_store_quangtrung=$PHOTO_OBJET_QUANGTRUNG_STORE_ID" \
  -v "photo_store_nowzone=$PHOTO_OBJET_NOWZONE_STORE_ID" \
  --file "$ROOT_DIR/scripts/apply_photo_objet_expected_slot_ledger.sql" \
  >/dev/null
psql_test --file "$ROOT_DIR/scripts/verify_photo_objet_expected_slot_ledger.sql" \
  | grep -q 'PHOTO_OBJET_EXPECTED_SLOT_VERIFY_PASS'

# Fixture B: production may not yet have the superseded immutable-health
# function. Apply must record that absence, and rollback must remove the
# compatibility function introduced by this migration.
psql_db photo_slot_missing_health_function >/dev/null <<'SQL'
DROP VIEW public.v_photo_objet_collection_health;
DROP FUNCTION public.photo_objet_collection_health_at(timestamptz);
INSERT INTO public.photo_objet_sales_raw (store_id, source_hash) VALUES (
  '77000000-0000-4000-8000-000000000001', 'fixture-missing-health-raw-immutable'
);
SQL
apply_fixture photo_slot_missing_health_function >/dev/null
apply_fixture photo_slot_missing_health_function >/dev/null
psql_db photo_slot_missing_health_function \
  --file "$ROOT_DIR/scripts/verify_photo_objet_expected_slot_ledger.sql" \
  | grep -q 'PHOTO_OBJET_EXPECTED_SLOT_VERIFY_PASS'
psql_db photo_slot_missing_health_function --single-transaction \
  --file "$ROOT_DIR/scripts/rollback_photo_objet_expected_slot_ledger.sql" \
  | grep -q 'PHOTO_OBJET_EXPECTED_SLOT_ROLLBACK_PASS'
psql_db photo_slot_missing_health_function -Atqc \
  "SELECT to_regprocedure('public.photo_objet_collection_health_at(timestamp with time zone)') IS NULL" \
  | grep -qx t
psql_db photo_slot_missing_health_function -Atqc \
  "SELECT to_regclass('public.v_photo_objet_collection_health') IS NULL" \
  | grep -qx t
psql_db photo_slot_missing_health_function -Atqc \
  "SELECT count(*) FROM public.photo_objet_sales_raw WHERE source_hash='fixture-missing-health-raw-immutable'" \
  | grep -qx 1

# Fixture C: an existing column keeps its complete catalog shape. The
# migration-created constraint is removed and the legacy comment is restored.
psql_db photo_slot_existing_column >/dev/null <<'SQL'
ALTER TABLE public.photo_objet_sales_pull_runs
  ADD COLUMN interval_rows integer NOT NULL DEFAULT 7;
COMMENT ON COLUMN public.photo_objet_sales_pull_runs.interval_rows IS
  'legacy interval rows comment';
INSERT INTO public.photo_objet_sales_raw (store_id, source_hash) VALUES (
  '77000000-0000-4000-8000-000000000001', 'fixture-b-raw-immutable'
);
SQL
fixture_b_before="$(catalog_fingerprint photo_slot_existing_column)"
psql_db photo_slot_existing_column \
  --file "$ROOT_DIR/scripts/preflight_photo_objet_expected_slot_ledger.sql" \
  | grep -q 'PHOTO_OBJET_EXPECTED_SLOT_PREFLIGHT_PASS'
apply_fixture photo_slot_existing_column >/dev/null
apply_fixture photo_slot_existing_column >/dev/null
psql_db photo_slot_existing_column --single-transaction \
  --file "$ROOT_DIR/scripts/rollback_photo_objet_expected_slot_ledger.sql" \
  | grep -q 'PHOTO_OBJET_EXPECTED_SLOT_ROLLBACK_PASS'
fixture_b_after="$(catalog_fingerprint photo_slot_existing_column)"
[[ "$fixture_b_after" = "$fixture_b_before" ]]
psql_db photo_slot_existing_column -Atqc \
  "SELECT count(*) FROM public.photo_objet_sales_raw WHERE source_hash='fixture-b-raw-immutable'" \
  | grep -qx 1

# Fixture D: a compatible pre-existing named constraint and legacy comment
# survive apply, replay, and rollback byte-for-byte at the catalog boundary.
psql_db photo_slot_existing_constraint >/dev/null <<'SQL'
ALTER TABLE public.photo_objet_sales_pull_runs
  ADD COLUMN interval_rows integer;
ALTER TABLE public.photo_objet_sales_pull_runs
  ADD CONSTRAINT photo_objet_pull_run_interval_rows_check
  CHECK (interval_rows IS NULL OR interval_rows >= 0);
COMMENT ON COLUMN public.photo_objet_sales_pull_runs.interval_rows IS
  'legacy constrained interval rows';
INSERT INTO public.photo_objet_sales_raw (store_id, source_hash) VALUES (
  '77000000-0000-4000-8000-000000000001', 'fixture-c-raw-immutable'
);
SQL
fixture_c_before="$(catalog_fingerprint photo_slot_existing_constraint)"
psql_db photo_slot_existing_constraint \
  --file "$ROOT_DIR/scripts/preflight_photo_objet_expected_slot_ledger.sql" \
  | grep -q 'PHOTO_OBJET_EXPECTED_SLOT_PREFLIGHT_PASS'
apply_fixture photo_slot_existing_constraint >/dev/null
apply_fixture photo_slot_existing_constraint >/dev/null
psql_db photo_slot_existing_constraint --single-transaction \
  --file "$ROOT_DIR/scripts/rollback_photo_objet_expected_slot_ledger.sql" \
  | grep -q 'PHOTO_OBJET_EXPECTED_SLOT_ROLLBACK_PASS'
fixture_c_after="$(catalog_fingerprint photo_slot_existing_constraint)"
[[ "$fixture_c_after" = "$fixture_c_before" ]]
psql_db photo_slot_existing_constraint -Atqc \
  "SELECT count(*) FROM public.photo_objet_sales_raw WHERE source_hash='fixture-c-raw-immutable'" \
  | grep -qx 1

# Fixture E1: an incompatible column type fails both preflight and direct
# migration execution without leaving schema mutations or changing raw rows.
psql_db photo_slot_bad_type >/dev/null <<'SQL'
ALTER TABLE public.photo_objet_sales_pull_runs ADD COLUMN interval_rows text;
INSERT INTO public.photo_objet_sales_raw (store_id, source_hash) VALUES (
  '77000000-0000-4000-8000-000000000001', 'fixture-d-type-raw-immutable'
);
SQL
fixture_d_type_before="$(catalog_fingerprint photo_slot_bad_type)"
set +e
fixture_d_type_preflight="$(psql_db photo_slot_bad_type \
  --file "$ROOT_DIR/scripts/preflight_photo_objet_expected_slot_ledger.sql" 2>&1)"
fixture_d_type_preflight_status=$?
fixture_d_type_apply="$(apply_fixture photo_slot_bad_type 2>&1)"
fixture_d_type_apply_status=$?
set -e
[[ "$fixture_d_type_preflight_status" -ne 0 ]]
[[ "$fixture_d_type_apply_status" -ne 0 ]]
[[ "$fixture_d_type_preflight" != *'PHOTO_OBJET_EXPECTED_SLOT_PREFLIGHT_PASS'* ]]
[[ "$fixture_d_type_apply" != *'PHOTO_OBJET_EXPECTED_SLOT_VERIFY_PASS'* ]]
[[ "$(catalog_fingerprint photo_slot_bad_type)" = "$fixture_d_type_before" ]]
psql_db photo_slot_bad_type -Atqc \
  "SELECT to_regclass('public.photo_objet_monitoring_policies') IS NULL" | grep -qx t
psql_db photo_slot_bad_type -Atqc \
  "SELECT count(*) FROM public.photo_objet_sales_raw WHERE source_hash='fixture-d-type-raw-immutable'" \
  | grep -qx 1

# Fixture E2: a same-named but incompatible constraint fails closed before any
# migration object survives the transaction.
psql_db photo_slot_bad_constraint >/dev/null <<'SQL'
ALTER TABLE public.photo_objet_sales_pull_runs ADD COLUMN interval_rows integer;
ALTER TABLE public.photo_objet_sales_pull_runs
  ADD CONSTRAINT photo_objet_pull_run_interval_rows_check
  CHECK (interval_rows IS NULL OR interval_rows <= 0);
INSERT INTO public.photo_objet_sales_raw (store_id, source_hash) VALUES (
  '77000000-0000-4000-8000-000000000001', 'fixture-d-constraint-raw-immutable'
);
SQL
fixture_d_constraint_before="$(catalog_fingerprint photo_slot_bad_constraint)"
set +e
fixture_d_constraint_preflight="$(psql_db photo_slot_bad_constraint \
  --file "$ROOT_DIR/scripts/preflight_photo_objet_expected_slot_ledger.sql" 2>&1)"
fixture_d_constraint_preflight_status=$?
fixture_d_constraint_apply="$(apply_fixture photo_slot_bad_constraint 2>&1)"
fixture_d_constraint_apply_status=$?
set -e
[[ "$fixture_d_constraint_preflight_status" -ne 0 ]]
[[ "$fixture_d_constraint_apply_status" -ne 0 ]]
[[ "$fixture_d_constraint_preflight" != *'PHOTO_OBJET_EXPECTED_SLOT_PREFLIGHT_PASS'* ]]
[[ "$fixture_d_constraint_apply" != *'PHOTO_OBJET_EXPECTED_SLOT_VERIFY_PASS'* ]]
[[ "$(catalog_fingerprint photo_slot_bad_constraint)" = "$fixture_d_constraint_before" ]]
psql_db photo_slot_bad_constraint -Atqc \
  "SELECT to_regclass('public.photo_objet_monitoring_policies') IS NULL" | grep -qx t
psql_db photo_slot_bad_constraint -Atqc \
  "SELECT count(*) FROM public.photo_objet_sales_raw WHERE source_hash='fixture-d-constraint-raw-immutable'" \
  | grep -qx 1

# Fixture F: switch the final slot from 23:00 to 22:30 without changing raw
# Moers rows or historical v1 policy semantics.
raw_before_2230="$(psql_test -Atqc "
  SELECT count(*) || '|' || md5(coalesce(string_agg(
    id::text || ':' || store_id::text || ':' || source_hash,
    '|' ORDER BY id
  ), ''))
  FROM public.photo_objet_sales_raw
")"
psql_test \
  -c "SET app.photo_objet_final_slot_cutover_date = '2026-07-14'" \
  --file "$ROOT_DIR/scripts/preflight_photo_objet_final_slot_2230.sql" \
  | grep -q 'PHOTO_OBJET_FINAL_SLOT_2230_PREFLIGHT_PASS'

for _ in 1 2; do
  psql_test --single-transaction \
    -c "SET app.photo_objet_final_slot_cutover_date = '2026-07-14'" \
    --file "$ROOT_DIR/supabase/migrations/20260714113000_photo_objet_final_slot_2230.sql" \
    >/dev/null
done
psql_test --file "$ROOT_DIR/scripts/verify_photo_objet_final_slot_2230.sql" \
  | grep -q 'PHOTO_OBJET_FINAL_SLOT_2230_VERIFY_PASS'

# Verification and rollback authenticate every owner-only evidence table before
# trusting it. Each tamper runs inside a failed transaction and is rolled back.
set +e
missing_evidence_output="$(psql_test --single-transaction \
  -c "DROP TABLE public.photo_slot_20260714113000_raw_identity_backup" \
  --file "$ROOT_DIR/scripts/verify_photo_objet_final_slot_2230.sql" 2>&1)"
missing_evidence_status=$?
set -e
[[ "$missing_evidence_status" -ne 0 ]]
[[ "$missing_evidence_output" == *'PHOTO_2230_VERIFY_BACKUP_MISSING'* ]]
[[ "$missing_evidence_output" != *'PHOTO_OBJET_FINAL_SLOT_2230_VERIFY_PASS'* ]]

set +e
deleted_expected_output="$(psql_test --single-transaction \
  -c "DELETE FROM public.photo_slot_20260714113000_expected_backup
      WHERE id = (SELECT id FROM public.photo_slot_20260714113000_expected_backup LIMIT 1)" \
  --file "$ROOT_DIR/scripts/verify_photo_objet_final_slot_2230.sql" 2>&1)"
deleted_expected_status=$?
set -e
[[ "$deleted_expected_status" -ne 0 ]]
[[ "$deleted_expected_output" == *'PHOTO_2230_VERIFY_EXPECTED_BACKUP_TAMPERED'* ]]
[[ "$deleted_expected_output" != *'PHOTO_OBJET_FINAL_SLOT_2230_VERIFY_PASS'* ]]

set +e
modified_map_output="$(psql_test --single-transaction \
  -c "UPDATE public.photo_slot_20260714113000_policy_map
      SET grace_minutes = grace_minutes + 1
      WHERE old_policy_id = (
        SELECT old_policy_id FROM public.photo_slot_20260714113000_policy_map LIMIT 1
      )" \
  --file "$ROOT_DIR/scripts/verify_photo_objet_final_slot_2230.sql" 2>&1)"
modified_map_status=$?
set -e
[[ "$modified_map_status" -ne 0 ]]
[[ "$modified_map_output" == *'PHOTO_2230_VERIFY_POLICY_MAP_TAMPERED'* ]]

set +e
rollback_map_output="$(psql_test --single-transaction \
  -c "UPDATE public.photo_slot_20260714113000_policy_map
      SET final_slot_grace_minutes = final_slot_grace_minutes + 1
      WHERE old_policy_id = (
        SELECT old_policy_id FROM public.photo_slot_20260714113000_policy_map LIMIT 1
      )" \
  --file "$ROOT_DIR/scripts/rollback_photo_objet_final_slot_2230.sql" 2>&1)"
rollback_map_status=$?
set -e
[[ "$rollback_map_status" -ne 0 ]]
[[ "$rollback_map_output" == *'PHOTO_2230_ROLLBACK_POLICY_MAP_TAMPERED'* ]]
[[ "$rollback_map_output" != *'PHOTO_OBJET_FINAL_SLOT_2230_ROLLBACK_PASS'* ]]

set +e
rollback_expected_output="$(psql_test --single-transaction \
  -c "UPDATE public.photo_slot_20260714113000_expected_backup
      SET status = 'tampered'
      WHERE id = (SELECT id FROM public.photo_slot_20260714113000_expected_backup LIMIT 1)" \
  --file "$ROOT_DIR/scripts/rollback_photo_objet_final_slot_2230.sql" 2>&1)"
rollback_expected_status=$?
set -e
[[ "$rollback_expected_status" -ne 0 ]]
[[ "$rollback_expected_output" == *'PHOTO_2230_ROLLBACK_EXPECTED_BACKUP_TAMPERED'* ]]
[[ "$rollback_expected_output" != *'PHOTO_OBJET_FINAL_SLOT_2230_ROLLBACK_PASS'* ]]

psql_test -Atqc "
  SELECT count(*)
  FROM public.photo_objet_monitoring_policies
  WHERE effective_to IS NULL
    AND schedule_version = 'hcm-two-hour-2230-v2'
" | grep -qx 6
psql_test -Atqc "
  SELECT count(*)
  FROM public.photo_objet_expected_slots
  WHERE slot_date_hcm = '2026-07-14'
    AND slot_time_hcm = TIME '22:30'
    AND scheduled_at = '2026-07-14 22:30:00+07'
    AND due_at = '2026-07-15 00:00:00+07'
" | grep -qx 6
psql_test -Atqc "
  SELECT count(*)
  FROM public.photo_objet_expected_slots
  WHERE slot_date_hcm = '2026-07-14'
    AND slot_time_hcm = TIME '23:00'
" | grep -qx 0
psql_test -Atqc "
  SELECT count(*)
  FROM public.photo_objet_expected_slots
  WHERE slot_date_hcm = '2026-07-14'
" | grep -qx 42
psql_test -Atqc "
  SELECT count(*)
  FROM pg_class
  WHERE oid IN (
    'public.photo_slot_20260714113000_state'::regclass,
    'public.photo_slot_20260714113000_policy_map'::regclass,
    'public.photo_slot_20260714113000_expected_backup'::regclass,
    'public.photo_slot_20260714113000_raw_identity_backup'::regclass
  )
    AND relrowsecurity = true
" | grep -qx 4
[[ "$(psql_test -Atqc "
  SELECT count(*) || '|' || md5(coalesce(string_agg(
    id::text || ':' || store_id::text || ':' || source_hash,
    '|' ORDER BY id
  ), ''))
  FROM public.photo_objet_sales_raw
")" = "$raw_before_2230" ]]

# A normal pre-final collection and a new immutable raw row must survive a
# schedule rollback. Only an attempted 22:30 final slot makes rollback unsafe.
psql_test -c "
  UPDATE public.photo_objet_expected_slots
  SET status = 'running', attempt_count = 1, updated_at = now()
  WHERE store_id = '$PHOTO_OBJET_BIENHOA_STORE_ID'
    AND slot_date_hcm = '2026-07-14'
    AND slot_time_hcm = TIME '20:00';
  INSERT INTO public.photo_objet_sales_raw (store_id, source_hash)
  VALUES ('$PHOTO_OBJET_BIENHOA_STORE_ID', 'raw-appended-after-2230-cutover');
" >/dev/null
raw_after_safe_append="$(psql_test -Atqc "
  SELECT count(*) || '|' || md5(coalesce(string_agg(
    id::text || ':' || store_id::text || ':' || source_hash,
    '|' ORDER BY id
  ), ''))
  FROM public.photo_objet_sales_raw
")"

psql_test --single-transaction \
  --file "$ROOT_DIR/scripts/rollback_photo_objet_final_slot_2230.sql" \
  | grep -q 'PHOTO_OBJET_FINAL_SLOT_2230_ROLLBACK_PASS'
psql_test -Atqc "
  SELECT count(*)
  FROM public.photo_objet_monitoring_policies
  WHERE effective_to IS NULL
    AND schedule_version = 'hcm-two-hour-v1'
" | grep -qx 6
psql_test -Atqc "
  SELECT count(*)
  FROM public.photo_objet_expected_slots
  WHERE slot_date_hcm = '2026-07-14'
    AND slot_time_hcm = TIME '23:00'
" | grep -qx 6
psql_test -Atqc "
  SELECT count(*)
  FROM public.photo_objet_expected_slots
  WHERE slot_date_hcm = '2026-07-14'
    AND slot_time_hcm = TIME '22:30'
" | grep -qx 0
[[ "$(psql_test -Atqc "
  SELECT count(*) || '|' || md5(coalesce(string_agg(
    id::text || ':' || store_id::text || ':' || source_hash,
    '|' ORDER BY id
  ), ''))
  FROM public.photo_objet_sales_raw
")" = "$raw_after_safe_append" ]]
psql_test -Atqc "
  SELECT status || '|' || attempt_count
  FROM public.photo_objet_expected_slots
  WHERE store_id = '$PHOTO_OBJET_BIENHOA_STORE_ID'
    AND slot_date_hcm = '2026-07-14'
    AND slot_time_hcm = TIME '20:00'
" | grep -qx 'running|1'

# Once the new final slot has started, rollback must fail closed instead of
# discarding live scheduler state.
psql_test --single-transaction \
  -c "SET app.photo_objet_final_slot_cutover_date = '2026-07-14'" \
  --file "$ROOT_DIR/supabase/migrations/20260714113000_photo_objet_final_slot_2230.sql" \
  >/dev/null
psql_test -c "
  UPDATE public.photo_objet_expected_slots
  SET status = 'running', attempt_count = 1, updated_at = now() + interval '1 second'
  WHERE store_id = '$PHOTO_OBJET_BIENHOA_STORE_ID'
    AND slot_date_hcm = '2026-07-14'
    AND slot_time_hcm = TIME '22:30'
" >/dev/null
set +e
rollback_live_output="$(psql_test --single-transaction \
  --file "$ROOT_DIR/scripts/rollback_photo_objet_final_slot_2230.sql" 2>&1)"
rollback_live_status=$?
set -e
[[ "$rollback_live_status" -ne 0 ]]
[[ "$rollback_live_output" == *'PHOTO_2230_ROLLBACK_LIVE_STATE_CHANGED'* ]]
[[ "$rollback_live_output" != *'PHOTO_OBJET_FINAL_SLOT_2230_ROLLBACK_PASS'* ]]
[[ "$(psql_test -Atqc "
  SELECT count(*) || '|' || md5(coalesce(string_agg(
    id::text || ':' || store_id::text || ':' || source_hash,
    '|' ORDER BY id
  ), ''))
  FROM public.photo_objet_sales_raw
")" = "$raw_after_safe_append" ]]

echo 'PHOTO_OBJET_EXPECTED_SLOT_LEDGER_TEST_PASS'
