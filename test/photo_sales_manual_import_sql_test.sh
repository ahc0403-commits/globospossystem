#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_PSQL="$(command -v psql)"
CONTAINER="globos-photo-manual-import-test-$$"

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

psql_test() {
  "$REAL_PSQL" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres \
    -X --no-psqlrc -v ON_ERROR_STOP=1 "$@"
}

psql_test >/dev/null <<'SQL'
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role;
CREATE SCHEMA auth;
CREATE SCHEMA extensions;
CREATE EXTENSION pgcrypto WITH SCHEMA extensions;
GRANT USAGE ON SCHEMA auth TO authenticated, service_role;

CREATE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated, service_role;

CREATE TABLE public.users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_id uuid NOT NULL UNIQUE,
  role text NOT NULL,
  is_active boolean NOT NULL DEFAULT true
);
CREATE FUNCTION public.is_super_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users
    WHERE auth_id = auth.uid() AND is_active = true AND role = 'super_admin'
  )
$$;

CREATE TABLE public.tax_entity (
  id uuid PRIMARY KEY,
  tax_code text NOT NULL,
  name text NOT NULL
);
CREATE TABLE public.restaurants (
  id uuid PRIMARY KEY,
  name text NOT NULL,
  brand_id uuid,
  tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id),
  short_code text,
  is_active boolean NOT NULL DEFAULT true
);
CREATE TABLE public.store_tax_entity_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  tax_entity_id uuid NOT NULL REFERENCES public.tax_entity(id),
  effective_from timestamptz NOT NULL,
  effective_to timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.photo_objet_sales_pull_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  target_date date NOT NULL,
  collector_method text NOT NULL DEFAULT 'excel',
  run_source text,
  slot_id text,
  slot_date_hcm date,
  slot_time_hcm time,
  interval_start_at timestamptz,
  interval_end_at timestamptz,
  status text NOT NULL DEFAULT 'started',
  rows_read integer NOT NULL DEFAULT 0,
  rows_inserted integer NOT NULL DEFAULT 0,
  rows_duplicate integer NOT NULL DEFAULT 0,
  aggregate_rows integer NOT NULL DEFAULT 0,
  interval_rows integer,
  error_message text,
  started_at timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.photo_objet_sales_raw (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  sale_date date NOT NULL,
  device_name text NOT NULL,
  device_id text,
  sale_time_text text,
  sold_at timestamptz NOT NULL,
  amount bigint NOT NULL CHECK (amount >= 0),
  raw_type text,
  payment_method text NOT NULL DEFAULT 'CASH',
  buyer_kind text NOT NULL DEFAULT 'anonymous',
  raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  source_hash text NOT NULL UNIQUE,
  source_identity_version integer NOT NULL DEFAULT 2,
  occurrence_no integer NOT NULL,
  interval_start_at timestamptz NOT NULL,
  interval_end_at timestamptz NOT NULL,
  pull_run_id uuid REFERENCES public.photo_objet_sales_pull_runs(id),
  meinvoice_job_id uuid,
  invoice_enqueue_status text NOT NULL DEFAULT 'pending',
  invoice_enqueue_error text,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.photo_objet_sales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  sale_date date NOT NULL,
  device_name text NOT NULL,
  device_id text,
  gross_sales bigint NOT NULL DEFAULT 0,
  service_amount bigint NOT NULL DEFAULT 0,
  transaction_count integer NOT NULL DEFAULT 0,
  service_count integer NOT NULL DEFAULT 0,
  raw_rows jsonb,
  pulled_at timestamptz NOT NULL DEFAULT now(),
  pull_source text NOT NULL DEFAULT 'scheduled',
  UNIQUE (store_id, sale_date, device_name)
);
CREATE TABLE public.audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid,
  action text NOT NULL,
  entity_type text NOT NULL,
  entity_id uuid,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.users (auth_id, role) VALUES
  ('10000000-0000-4000-8000-000000000001', 'super_admin'),
  ('10000000-0000-4000-8000-000000000002', 'photo_objet_master');
INSERT INTO public.tax_entity (id, tax_code, name) VALUES
  ('20000000-0000-4000-8000-000000000001', '0318453298', 'AKJ INTERNATIONAL');
INSERT INTO public.restaurants (
  id, name, brand_id, tax_entity_id, short_code
) VALUES
  ('77000000-0000-4000-8000-000000000102', 'PHOTO OBJET BIEN HOA', '77000000-0000-0000-0000-000000000001', '20000000-0000-4000-8000-000000000001', 'BH'),
  ('77000000-0000-4000-8000-000000000103', 'PHOTO OBJET DI AN', '77000000-0000-0000-0000-000000000001', '20000000-0000-4000-8000-000000000001', 'DA');
INSERT INTO public.store_tax_entity_history (
  store_id, tax_entity_id, effective_from
) SELECT
  id,
  tax_entity_id,
  TIMESTAMPTZ '2026-01-01 00:00:00+07'
FROM public.restaurants;
SQL

psql_test --single-transaction \
  --file "$ROOT_DIR/supabase/migrations/20260903090000_photo_sales_manual_branch_import.sql" \
  >/dev/null

psql_test >/dev/null <<'SQL'
SET ROLE authenticated;
SELECT set_config(
  'request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000001',
  false
);

SELECT public.import_photo_objet_sales_excel(
  DATE '2026-09-02',
  'moers.xlsx',
  '[
    {"source_row":2,"branch_code":"BH","store_name":"Moers BH","device_name":"BH-1","device_id":"D-BH","sale_time":"10:00:00","amount":100000,"raw_type":"현금","occurrence_no":1},
    {"source_row":3,"branch_code":"BH","store_name":"Moers BH","device_name":"BH-1","device_id":"D-BH","sale_time":"10:00:00","amount":100000,"raw_type":"현금","occurrence_no":2},
    {"source_row":4,"branch_code":"DA","store_name":"Moers DA","device_name":"DA-1","device_id":"D-DA","sale_time":"11:00:00","amount":50000,"raw_type":"현금","occurrence_no":1}
  ]'::jsonb
);
RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.photo_objet_sales_raw) <> 3 THEN
    RAISE EXCEPTION 'PHOTO_MANUAL_IMPORT_RAW_COUNT_FAILED';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.photo_objet_sales_raw
    WHERE source_hash = '199c9bda9cc7bff033d2c3c84013bccff35f3ea0c18c3c299d6d771dd148c791'
  ) THEN
    RAISE EXCEPTION 'PHOTO_MANUAL_IMPORT_COLLECTOR_HASH_COMPATIBILITY_FAILED';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.photo_objet_sales
    WHERE store_id = '77000000-0000-4000-8000-000000000102'
      AND sale_date = DATE '2026-09-02'
      AND device_name = 'BH-1'
      AND gross_sales = 200000
      AND transaction_count = 2
      AND pull_source = 'manual'
  ) THEN
    RAISE EXCEPTION 'PHOTO_MANUAL_IMPORT_BH_AGGREGATE_FAILED';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.photo_objet_sales
    WHERE store_id = '77000000-0000-4000-8000-000000000103'
      AND gross_sales = 50000
      AND transaction_count = 1
  ) THEN
    RAISE EXCEPTION 'PHOTO_MANUAL_IMPORT_DA_AGGREGATE_FAILED';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT public.import_photo_objet_sales_excel(
  DATE '2026-09-02',
  'moers.xlsx',
  '[
    {"source_row":2,"branch_code":"BH","store_name":"Moers BH","device_name":"BH-1","device_id":"D-BH","sale_time":"10:00:00","amount":100000,"raw_type":"현금","occurrence_no":1},
    {"source_row":3,"branch_code":"BH","store_name":"Moers BH","device_name":"BH-1","device_id":"D-BH","sale_time":"10:00:00","amount":100000,"raw_type":"현금","occurrence_no":2},
    {"source_row":4,"branch_code":"DA","store_name":"Moers DA","device_name":"DA-1","device_id":"D-DA","sale_time":"11:00:00","amount":50000,"raw_type":"현금","occurrence_no":1}
  ]'::jsonb
);
RESET ROLE;

DO $$
BEGIN
  IF (SELECT count(*) FROM public.photo_objet_sales_raw) <> 3
     OR (SELECT sum(gross_sales) FROM public.photo_objet_sales) <> 250000 THEN
    RAISE EXCEPTION 'PHOTO_MANUAL_IMPORT_REPLAY_NOT_IDEMPOTENT';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.photo_objet_sales_pull_runs
    WHERE status = 'success' AND rows_inserted = 0 AND rows_duplicate > 0
  ) THEN
    RAISE EXCEPTION 'PHOTO_MANUAL_IMPORT_DUPLICATE_RUN_MISSING';
  END IF;
END;
$$;

SET ROLE authenticated;
SELECT set_config(
  'request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000002',
  false
);
DO $$
BEGIN
  BEGIN
    PERFORM public.import_photo_objet_sales_excel(
      DATE '2026-09-02',
      'forbidden.xlsx',
      '[{"source_row":2,"branch_code":"BH","device_name":"X","sale_time":"12:00:00","amount":1,"occurrence_no":1}]'::jsonb
    );
    RAISE EXCEPTION 'PHOTO_MANUAL_IMPORT_FORBIDDEN_WAS_ALLOWED';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM = 'PHOTO_MANUAL_IMPORT_FORBIDDEN_WAS_ALLOWED' THEN RAISE; END IF;
    IF SQLERRM <> 'PHOTO_SALES_IMPORT_FORBIDDEN' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.get_photo_sales_misa_exports_by_tax_entity(
      DATE '2026-09-02'
    );
    RAISE EXCEPTION 'PHOTO_SALES_EXPORT_FORBIDDEN_WAS_ALLOWED';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM = 'PHOTO_SALES_EXPORT_FORBIDDEN_WAS_ALLOWED' THEN RAISE; END IF;
    IF SQLERRM <> 'PHOTO_SALES_EXPORT_FORBIDDEN' THEN RAISE; END IF;
  END;
END;
$$;

SELECT set_config(
  'request.jwt.claim.sub',
  '10000000-0000-4000-8000-000000000001',
  false
);
DO $$
DECLARE
  v_export jsonb;
BEGIN
  v_export := public.get_photo_sales_misa_exports_by_tax_entity(
    DATE '2026-09-02'
  );
  IF v_export->>'business_date' <> '2026-09-02'
     OR (v_export->>'entity_count')::integer <> 1
     OR (v_export#>>'{entities,0,store_count}')::integer <> 2
     OR (v_export#>>'{entities,0,receipt_count}')::integer <> 3
     OR (v_export#>>'{entities,0,gross_sales}')::bigint <> 250000
     OR v_export#>>'{entities,0,seller_tax_code}' <> '0318453298' THEN
    RAISE EXCEPTION 'PHOTO_MANUAL_IMPORT_MISA_EXPORT_FAILED:%', v_export;
  END IF;
END;
$$;
RESET ROLE;
SQL

echo 'PHOTO_SALES_MANUAL_IMPORT_SQL_TEST_PASS'
