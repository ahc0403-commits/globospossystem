#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CONTAINER="globos-photo-retirement-test-$$"
cleanup() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run --detach --rm --name "$CONTAINER" \
  --env POSTGRES_PASSWORD=retirement-fixture \
  --env POSTGRES_DB=retirement_test \
  public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null

for attempt in $(seq 1 60); do
  if docker exec "$CONTAINER" pg_isready -h 127.0.0.1 -U postgres \
    -d retirement_test >/dev/null 2>&1; then
    break
  fi
  [[ "$attempt" != 60 ]] || exit 1
  sleep 1
done

run_sql() {
  docker exec -i --env PGPASSWORD=retirement-fixture "$CONTAINER" \
    psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d retirement_test "$@"
}

run_sql >/dev/null <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role;
  END IF;
END;
$$;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA cron;

CREATE TABLE cron.job (jobname text PRIMARY KEY);
CREATE FUNCTION cron.unschedule(p_jobname text)
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM cron.job WHERE jobname = p_jobname;
  RETURN FOUND;
END;
$$;

CREATE TABLE public.restaurants (id uuid PRIMARY KEY);
CREATE TABLE public.photo_objet_monitoring_policies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  store_id uuid NOT NULL REFERENCES public.restaurants(id),
  effective_from timestamptz NOT NULL,
  effective_to timestamptz,
  is_enabled boolean NOT NULL DEFAULT true
);
CREATE TABLE public.photo_objet_expected_slots (id uuid PRIMARY KEY);
CREATE TABLE public.photo_objet_sales_pull_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_source text
);
CREATE TABLE public.photo_objet_sales_raw (id uuid PRIMARY KEY DEFAULT gen_random_uuid());

GRANT ALL ON public.photo_objet_expected_slots TO service_role;
GRANT ALL ON public.photo_objet_sales_pull_runs TO service_role;
GRANT ALL ON public.photo_objet_sales_raw TO service_role;

INSERT INTO public.restaurants VALUES ('77000000-0000-0000-0000-000000000102');
INSERT INTO public.photo_objet_monitoring_policies (
  store_id, effective_from, effective_to, is_enabled
) VALUES (
  '77000000-0000-0000-0000-000000000102', now() - interval '1 day', NULL, true
);
INSERT INTO cron.job VALUES ('photo-objet-materialize-expected-slots');

CREATE FUNCTION public.photo_objet_ensure_expected_slots(date, date)
RETURNS integer LANGUAGE sql AS $$ SELECT 0 $$;
GRANT EXECUTE ON FUNCTION public.photo_objet_ensure_expected_slots(date, date)
  TO PUBLIC, anon, authenticated, service_role;
SQL

for attempt in 1 2; do
  run_sql < supabase/migrations/20260916060000_retire_photo_objet_automatic_sales_collection.sql \
    >/dev/null
done

run_sql >/dev/null <<'SQL'
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.photo_objet_monitoring_policies
    WHERE is_enabled OR effective_to IS NULL
  ) THEN
    RAISE EXCEPTION 'retirement did not close every monitoring policy';
  END IF;

  IF EXISTS (
    SELECT 1 FROM cron.job
    WHERE jobname = 'photo-objet-materialize-expected-slots'
  ) THEN
    RAISE EXCEPTION 'retirement did not remove the materialization cron';
  END IF;

  IF has_function_privilege(
    'service_role',
    'public.photo_objet_ensure_expected_slots(date,date)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'service_role retained retired scheduler execution';
  END IF;

  IF has_table_privilege(
    'service_role',
    'public.photo_objet_sales_pull_runs',
    'INSERT'
  ) OR has_table_privilege(
    'service_role',
    'public.photo_objet_sales_raw',
    'INSERT'
  ) THEN
    RAISE EXCEPTION 'service_role retained automatic collection table writes';
  END IF;

  BEGIN
    UPDATE public.photo_objet_monitoring_policies
    SET is_enabled = true, effective_to = NULL;
    RAISE EXCEPTION 'retirement trigger allowed reactivation';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'PHOTO_OBJET_AUTOMATIC_SALES_COLLECTION_RETIRED' THEN
        RAISE;
      END IF;
  END;

  BEGIN
    INSERT INTO public.photo_objet_sales_pull_runs (run_source)
    VALUES ('scheduled');
    RAISE EXCEPTION 'retirement trigger allowed a scheduled sales run';
  EXCEPTION
    WHEN raise_exception THEN
      IF SQLERRM <> 'PHOTO_OBJET_AUTOMATIC_SALES_COLLECTION_RETIRED' THEN
        RAISE;
      END IF;
  END;

  INSERT INTO public.photo_objet_sales_pull_runs (run_source)
  VALUES ('manual');
END;
$$;
SQL

printf 'PHOTO_OBJET_SALES_COLLECTION_RETIREMENT_SQL_TEST=PASS\n'
