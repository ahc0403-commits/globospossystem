#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_PSQL="$(command -v psql)"
CONTAINER="globos-photo-health-test-$$"

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
CREATE ROLE authenticated;
CREATE ROLE service_role;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE public.restaurants (
  id uuid PRIMARY KEY,
  brand_id uuid,
  is_active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.photo_objet_sales_pull_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  target_date date NOT NULL,
  run_source text,
  slot_date_hcm date,
  slot_time_hcm time,
  status text NOT NULL,
  finished_at timestamptz
);

CREATE TABLE public.photo_objet_sales_raw (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  sale_date date NOT NULL,
  device_name text NOT NULL,
  device_id text,
  sale_time_text text,
  sold_at timestamptz NOT NULL,
  amount bigint NOT NULL,
  raw_type text,
  payment_method text NOT NULL,
  buyer_kind text NOT NULL,
  raw_payload jsonb NOT NULL,
  source_hash text NOT NULL UNIQUE,
  source_identity_version integer NOT NULL,
  occurrence_no integer NOT NULL,
  interval_start_at timestamptz NOT NULL,
  interval_end_at timestamptz NOT NULL,
  pull_run_id uuid,
  meinvoice_job_id uuid,
  invoice_enqueue_status text NOT NULL DEFAULT 'pending',
  invoice_enqueue_error text,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, UPDATE, DELETE ON public.photo_objet_sales_raw TO service_role;
SQL

psql_test --single-transaction \
  --file "$ROOT_DIR/supabase/migrations/20260713090000_photo_objet_immutable_health.sql" \
  >/dev/null

psql_test >/dev/null <<'SQL'
INSERT INTO public.restaurants (id, brand_id, is_active) VALUES (
  '77000000-0000-4000-8000-000000000102',
  '77000000-0000-0000-0000-000000000001',
  true
);

DO $$
DECLARE health record;
BEGIN
  SELECT * INTO health
  FROM public.photo_objet_collection_health_at('2026-07-14 08:00:00+07')
  WHERE store_id = '77000000-0000-4000-8000-000000000102'
    AND target_date = '2026-07-14';
  IF health.expected_slots <> 15 OR health.due_slots <> 0
     OR health.status <> 'not_due' OR health.is_healthy THEN
    RAISE EXCEPTION 'PHOTO_HEALTH_BEFORE_FIRST_SLOT_FAILED: %', row_to_json(health);
  END IF;
END $$;

INSERT INTO public.photo_objet_sales_pull_runs (
  store_id, target_date, run_source, slot_date_hcm, slot_time_hcm, status, finished_at
) VALUES (
  '77000000-0000-4000-8000-000000000102', '2026-07-14', 'scheduled',
  '2026-07-14', '10:00', 'success', '2026-07-14 10:05:00+07'
);

DO $$
DECLARE health record;
BEGIN
  SELECT * INTO health
  FROM public.photo_objet_collection_health_at('2026-07-14 10:20:00+07')
  WHERE store_id = '77000000-0000-4000-8000-000000000102'
    AND target_date = '2026-07-14';
  IF health.due_slots <> 1 OR health.successful_slots <> 0
     OR health.missing_slots <> 1 OR health.status <> 'missing'
     OR health.is_healthy THEN
    RAISE EXCEPTION 'PHOTO_HEALTH_LATER_SUCCESS_HID_GAP: %', row_to_json(health);
  END IF;
END $$;

INSERT INTO public.photo_objet_sales_raw (
  store_id, sale_date, device_name, sold_at, amount, payment_method, buyer_kind,
  raw_payload, source_hash, source_identity_version, occurrence_no,
  interval_start_at, interval_end_at
) VALUES (
  '77000000-0000-4000-8000-000000000102', '2026-07-14', 'M1',
  '2026-07-14 09:30:00+07', 100000, 'CASH', 'anonymous',
  '{"row":{"Amount":"100000"}}', 'immutable-hash', 2, 1,
  '2026-07-14 09:00:00+07', '2026-07-14 10:00:00+07'
);

SET ROLE service_role;
UPDATE public.photo_objet_sales_raw
SET invoice_enqueue_status = 'queued', updated_at = now()
WHERE source_hash = 'immutable-hash';

DO $$
BEGIN
  BEGIN
    UPDATE public.photo_objet_sales_raw
    SET amount = 90000
    WHERE source_hash = 'immutable-hash';
    RAISE EXCEPTION 'PHOTO_RAW_IDENTITY_UPDATE_WAS_ALLOWED';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'PHOTO_RAW_IDENTITY_UPDATE_WAS_ALLOWED' THEN RAISE; END IF;
      IF SQLERRM <> 'PHOTO_OBJET_RAW_IDENTITY_IMMUTABLE' THEN RAISE; END IF;
  END;

  BEGIN
    DELETE FROM public.photo_objet_sales_raw WHERE source_hash = 'immutable-hash';
    RAISE EXCEPTION 'PHOTO_RAW_DELETE_WAS_ALLOWED';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM = 'PHOTO_RAW_DELETE_WAS_ALLOWED' THEN RAISE; END IF;
      IF SQLERRM <> 'PHOTO_OBJET_RAW_DELETE_FORBIDDEN' THEN RAISE; END IF;
  END;
END $$;
RESET ROLE;
SQL

echo 'PHOTO_OBJET_IMMUTABLE_HEALTH_SQL_TEST_PASS'
