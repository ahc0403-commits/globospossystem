\set ON_ERROR_STOP on

DO $$
DECLARE
  v_interval_rows_type text;
  v_interval_rows_constraint text;
BEGIN
  IF to_regclass('public.photo_objet_sales_raw') IS NULL
     OR to_regclass('public.photo_objet_sales_pull_runs') IS NULL
     OR to_regclass('public.restaurants') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_SLOT_PREFLIGHT_BASE_SCHEMA_MISSING';
  END IF;
  IF to_regprocedure('public.user_accessible_stores(uuid)') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_SLOT_PREFLIGHT_ACCESS_HELPER_MISSING';
  END IF;
  IF to_regclass('public.v_office_eligible_stores') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_SLOT_PREFLIGHT_OFFICE_SCOPE_MISSING';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'v_office_eligible_stores'
      AND column_name = 'store_id'
  ) THEN
    RAISE EXCEPTION 'PHOTO_SLOT_PREFLIGHT_OFFICE_STORE_ID_COLUMN_MISSING';
  END IF;
  IF to_regclass('public.photo_objet_sales') IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class child ON child.oid = c.conrelid
    JOIN pg_class parent ON parent.oid = c.confrelid
    JOIN pg_namespace n ON n.oid = child.relnamespace
    WHERE c.contype = 'f'
      AND n.nspname = 'public'
      AND child.relname = 'photo_objet_sales'
      AND parent.relname = 'restaurants'
  ) THEN
    RAISE EXCEPTION 'PHOTO_SLOT_PREFLIGHT_AGGREGATE_STORE_FK_NOT_NORMALIZED';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.photo_objet_sales_pull_runs
    WHERE run_source = 'scheduled'
      AND (slot_date_hcm IS NULL OR slot_time_hcm IS NULL)
  ) THEN
    RAISE EXCEPTION 'PHOTO_SLOT_PREFLIGHT_TYPED_RUN_IDENTITY_MISSING';
  END IF;

  SELECT format_type(a.atttypid, a.atttypmod) INTO v_interval_rows_type
  FROM pg_attribute a
  WHERE a.attrelid = 'public.photo_objet_sales_pull_runs'::regclass
    AND a.attname = 'interval_rows' AND NOT a.attisdropped;
  IF v_interval_rows_type IS NOT NULL AND v_interval_rows_type <> 'integer' THEN
    RAISE EXCEPTION 'PHOTO_SLOT_PREFLIGHT_INTERVAL_ROWS_TYPE_INCOMPATIBLE: %',
      v_interval_rows_type;
  END IF;

  SELECT pg_get_constraintdef(c.oid, true) INTO v_interval_rows_constraint
  FROM pg_constraint c
  WHERE c.conrelid = 'public.photo_objet_sales_pull_runs'::regclass
    AND c.conname = 'photo_objet_pull_run_interval_rows_check';
  IF v_interval_rows_constraint IS NOT NULL
     AND v_interval_rows_constraint <> 'CHECK (interval_rows IS NULL OR interval_rows >= 0)' THEN
    RAISE EXCEPTION 'PHOTO_SLOT_PREFLIGHT_INTERVAL_ROWS_CONSTRAINT_INCOMPATIBLE: %',
      v_interval_rows_constraint;
  END IF;
END $$;

SELECT 'PHOTO_OBJET_EXPECTED_SLOT_PREFLIGHT_PASS' AS result;
