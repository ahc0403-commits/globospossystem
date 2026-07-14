\set ON_ERROR_STOP on

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'photo-objet-materialize-expected-slots') THEN
      PERFORM cron.unschedule('photo-objet-materialize-expected-slots');
    END IF;
  END IF;
END $$;

DROP VIEW IF EXISTS public.v_office_photo_objet_expected_slot_health;
DROP VIEW IF EXISTS public.v_photo_objet_expected_slot_health;
DO $$
DECLARE v_definition text;
BEGIN
  SELECT prior_health_function_definition INTO v_definition
  FROM public.photo_slot_20260713120000_state
  WHERE migration_id = '20260713120000';
  IF v_definition IS NULL THEN
    RAISE EXCEPTION 'PHOTO_SLOT_ROLLBACK_HEALTH_BACKUP_MISSING';
  END IF;
  EXECUTE v_definition;
END $$;
DROP FUNCTION IF EXISTS public.photo_objet_expected_slot_health_at(timestamptz, integer);
DROP FUNCTION IF EXISTS public.photo_objet_ack_expected_slot_alert(uuid, date, time, text, timestamptz);
DROP FUNCTION IF EXISTS public.photo_objet_refresh_expected_slot_health(timestamptz, integer);
DROP FUNCTION IF EXISTS public.photo_objet_fail_expected_slot(uuid, date, time, text);
DROP FUNCTION IF EXISTS public.photo_objet_complete_expected_slot(uuid, date, time, uuid, boolean);
DROP FUNCTION IF EXISTS public.photo_objet_claim_expected_slot(uuid, date, time, uuid);
DROP FUNCTION IF EXISTS public.photo_objet_ensure_expected_slots(date, date);
DROP TABLE IF EXISTS public.photo_objet_expected_slots;
DROP TABLE IF EXISTS public.photo_objet_monitoring_policies;
DROP FUNCTION IF EXISTS public.enforce_photo_objet_monitoring_policy_period();
DO $$
DECLARE
  v_interval_rows_existed boolean;
  v_data_type text;
  v_not_null boolean;
  v_default text;
  v_comment text;
  v_constraint_existed boolean;
  v_constraint_definition text;
  v_current_data_type text;
  v_current_not_null boolean;
  v_current_default text;
  v_current_comment text;
  v_current_constraint_definition text;
BEGIN
  SELECT
    pull_run_interval_rows_existed,
    pull_run_interval_rows_data_type,
    pull_run_interval_rows_not_null,
    pull_run_interval_rows_default,
    pull_run_interval_rows_comment,
    pull_run_interval_rows_constraint_existed,
    pull_run_interval_rows_constraint_definition
  INTO
    v_interval_rows_existed,
    v_data_type,
    v_not_null,
    v_default,
    v_comment,
    v_constraint_existed,
    v_constraint_definition
  FROM public.photo_slot_20260713120000_state
  WHERE migration_id = '20260713120000';
  IF NOT FOUND OR v_interval_rows_existed IS NULL
     OR v_constraint_existed IS NULL THEN
    RAISE EXCEPTION 'PHOTO_SLOT_ROLLBACK_INTERVAL_ROWS_STATE_MISSING';
  END IF;
  IF v_interval_rows_existed = false THEN
    ALTER TABLE public.photo_objet_sales_pull_runs
      DROP COLUMN IF EXISTS interval_rows;
  ELSE
    SELECT
      format_type(a.atttypid, a.atttypmod),
      a.attnotnull,
      pg_get_expr(d.adbin, d.adrelid),
      col_description(a.attrelid, a.attnum)
    INTO
      v_current_data_type,
      v_current_not_null,
      v_current_default,
      v_current_comment
    FROM pg_attribute a
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
    WHERE a.attrelid = 'public.photo_objet_sales_pull_runs'::regclass
      AND a.attname = 'interval_rows' AND NOT a.attisdropped;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'PHOTO_SLOT_ROLLBACK_INTERVAL_ROWS_COLUMN_MISSING';
    END IF;
    IF v_current_data_type IS DISTINCT FROM v_data_type
       OR v_current_not_null IS DISTINCT FROM v_not_null
       OR v_current_default IS DISTINCT FROM v_default THEN
      RAISE EXCEPTION 'PHOTO_SLOT_ROLLBACK_INTERVAL_ROWS_SHAPE_DRIFT';
    END IF;

    SELECT pg_get_constraintdef(c.oid, true)
    INTO v_current_constraint_definition
    FROM pg_constraint c
    WHERE c.conrelid = 'public.photo_objet_sales_pull_runs'::regclass
      AND c.conname = 'photo_objet_pull_run_interval_rows_check';
    IF v_constraint_existed THEN
      IF v_constraint_definition IS NULL THEN
        RAISE EXCEPTION 'PHOTO_SLOT_ROLLBACK_CONSTRAINT_BACKUP_MISSING';
      END IF;
      IF v_current_constraint_definition IS DISTINCT FROM v_constraint_definition THEN
        ALTER TABLE public.photo_objet_sales_pull_runs
          DROP CONSTRAINT IF EXISTS photo_objet_pull_run_interval_rows_check;
        EXECUTE format(
          'ALTER TABLE public.photo_objet_sales_pull_runs ADD CONSTRAINT %I %s',
          'photo_objet_pull_run_interval_rows_check',
          v_constraint_definition
        );
      END IF;
    ELSE
      ALTER TABLE public.photo_objet_sales_pull_runs
        DROP CONSTRAINT IF EXISTS photo_objet_pull_run_interval_rows_check;
    END IF;

    EXECUTE format(
      'COMMENT ON COLUMN public.photo_objet_sales_pull_runs.interval_rows IS %L',
      v_comment
    );

    SELECT
      col_description(a.attrelid, a.attnum),
      (
        SELECT pg_get_constraintdef(c.oid, true)
        FROM pg_constraint c
        WHERE c.conrelid = a.attrelid
          AND c.conname = 'photo_objet_pull_run_interval_rows_check'
      )
    INTO v_current_comment, v_current_constraint_definition
    FROM pg_attribute a
    WHERE a.attrelid = 'public.photo_objet_sales_pull_runs'::regclass
      AND a.attname = 'interval_rows' AND NOT a.attisdropped;
    IF v_current_comment IS DISTINCT FROM v_comment
       OR (v_constraint_existed
           AND v_current_constraint_definition IS DISTINCT FROM v_constraint_definition)
       OR (NOT v_constraint_existed AND v_current_constraint_definition IS NOT NULL) THEN
      RAISE EXCEPTION 'PHOTO_SLOT_ROLLBACK_INTERVAL_ROWS_RESTORE_FAILED';
    END IF;
  END IF;
END $$;
DROP TABLE IF EXISTS public.photo_slot_20260713120000_state;

SELECT 'PHOTO_OBJET_EXPECTED_SLOT_ROLLBACK_PASS' AS result;
