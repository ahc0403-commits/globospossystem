\set ON_ERROR_STOP on

-- Read-only production preflight for the native print station pilot.
-- This script intentionally performs no INSERT, UPDATE, DELETE, or DDL.

DO $$
DECLARE
  v_missing integer;
BEGIN
  IF to_regclass('public.restaurants') IS NULL
     OR to_regclass('public.tables') IS NULL
     OR to_regclass('public.printer_destinations') IS NULL
     OR to_regclass('public.print_jobs') IS NULL THEN
    RAISE EXCEPTION 'PRINT_STATION_REQUIRED_RELATION_MISSING';
  END IF;

  SELECT count(*) INTO v_missing
  FROM (
    VALUES
      ('restaurants', 'id'),
      ('restaurants', 'name'),
      ('restaurants', 'slug'),
      ('restaurants', 'operation_mode'),
      ('restaurants', 'is_active'),
      ('tables', 'id'),
      ('tables', 'restaurant_id'),
      ('tables', 'table_number'),
      ('tables', 'floor_label'),
      ('tables', 'status'),
      ('printer_destinations', 'id'),
      ('printer_destinations', 'restaurant_id'),
      ('printer_destinations', 'name'),
      ('printer_destinations', 'ip'),
      ('printer_destinations', 'port'),
      ('printer_destinations', 'purpose'),
      ('printer_destinations', 'floor_label'),
      ('printer_destinations', 'is_active'),
      ('print_jobs', 'status'),
      ('print_jobs', 'destination_id')
  ) required(table_name, column_name)
  LEFT JOIN information_schema.columns column_info
    ON column_info.table_schema = 'public'
   AND column_info.table_name = required.table_name
   AND column_info.column_name = required.column_name
  WHERE column_info.column_name IS NULL;

  IF v_missing <> 0 THEN
    RAISE EXCEPTION 'PRINT_STATION_REQUIRED_COLUMN_MISSING: %', v_missing;
  END IF;

  IF to_regprocedure('public.admin_upsert_printer_destination(uuid,uuid,text,text,integer,text,text,boolean)') IS NULL THEN
    RAISE EXCEPTION 'PRINT_STATION_ADMIN_UPSERT_RPC_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_class relation
    WHERE relation.oid = 'public.printer_destinations'::regclass
      AND relation.relrowsecurity
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_class relation
    WHERE relation.oid = 'public.print_jobs'::regclass
      AND relation.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'PRINT_STATION_RLS_NOT_ENABLED';
  END IF;
END $$;

SELECT
  id AS restaurant_id,
  name,
  slug,
  operation_mode,
  is_active
FROM public.restaurants
ORDER BY is_active DESC, name, id;

SELECT
  restaurant_id,
  id AS destination_id,
  name,
  purpose,
  floor_label,
  ip,
  port,
  is_active
FROM public.printer_destinations
ORDER BY restaurant_id, purpose, floor_label NULLS FIRST, name, id;

SELECT
  restaurant_id,
  COALESCE(NULLIF(btrim(floor_label), ''), '<EMPTY>') AS floor_label,
  count(*) AS table_count
FROM public.tables
GROUP BY restaurant_id, COALESCE(NULLIF(btrim(floor_label), ''), '<EMPTY>')
ORDER BY restaurant_id, floor_label;

SELECT
  restaurant_id,
  id AS table_id,
  table_number,
  floor_label,
  status
FROM public.tables
ORDER BY restaurant_id, floor_label, table_number, id;

SELECT
  restaurant_id,
  status,
  count(*) AS job_count
FROM public.print_jobs
GROUP BY restaurant_id, status
ORDER BY restaurant_id, status;

SELECT 'PRINT_STATION_PILOT_PREFLIGHT_OK' AS result;
