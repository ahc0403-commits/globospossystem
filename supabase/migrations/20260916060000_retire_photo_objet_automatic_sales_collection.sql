-- production-gate: self-verifying
-- Photo Objet automatic sales collection is permanently retired.
BEGIN;

DO $retire_cron$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM cron.job
    WHERE jobname = 'photo-objet-materialize-expected-slots'
  ) THEN
    PERFORM cron.unschedule('photo-objet-materialize-expected-slots');
  END IF;
END;
$retire_cron$;

UPDATE public.photo_objet_monitoring_policies
SET
  is_enabled = false,
  effective_to = CASE
    WHEN effective_to IS NULL
      THEN GREATEST(statement_timestamp(), effective_from + interval '1 microsecond')
    ELSE effective_to
  END
WHERE is_enabled OR effective_to IS NULL;

CREATE OR REPLACE FUNCTION public.reject_photo_objet_collection_reactivation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public'
AS $$
BEGIN
  IF NEW.is_enabled OR NEW.effective_to IS NULL THEN
    RAISE EXCEPTION 'PHOTO_OBJET_AUTOMATIC_SALES_COLLECTION_RETIRED'
      USING HINT = 'Automatic collection may be reintroduced only by an explicit new product decision and migration.';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.reject_photo_objet_collection_reactivation()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS trg_reject_photo_objet_collection_reactivation
  ON public.photo_objet_monitoring_policies;
CREATE TRIGGER trg_reject_photo_objet_collection_reactivation
BEFORE INSERT OR UPDATE OF is_enabled, effective_to
ON public.photo_objet_monitoring_policies
FOR EACH ROW
EXECUTE FUNCTION public.reject_photo_objet_collection_reactivation();

CREATE OR REPLACE FUNCTION public.reject_photo_objet_automatic_sales_run()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public'
AS $$
BEGIN
  IF NEW.run_source IS DISTINCT FROM 'manual' THEN
    RAISE EXCEPTION 'PHOTO_OBJET_AUTOMATIC_SALES_COLLECTION_RETIRED'
      USING HINT = 'Only the explicit Super Admin Excel import may create Photo sales runs.';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.reject_photo_objet_automatic_sales_run()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS trg_reject_photo_objet_automatic_sales_run
  ON public.photo_objet_sales_pull_runs;
CREATE TRIGGER trg_reject_photo_objet_automatic_sales_run
BEFORE INSERT OR UPDATE OF run_source
ON public.photo_objet_sales_pull_runs
FOR EACH ROW
EXECUTE FUNCTION public.reject_photo_objet_automatic_sales_run();

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON TABLE public.photo_objet_expected_slots
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE
  ON TABLE public.photo_objet_sales_pull_runs
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE INSERT, DELETE, TRUNCATE
  ON TABLE public.photo_objet_sales_raw
  FROM PUBLIC, anon, authenticated, service_role;

DO $revoke_retired_collection_rpcs$
DECLARE
  v_function record;
BEGIN
  FOR v_function IN
    SELECT
      namespace.nspname AS schema_name,
      procedure_row.proname AS function_name,
      pg_get_function_identity_arguments(procedure_row.oid) AS arguments
    FROM pg_proc procedure_row
    JOIN pg_namespace namespace ON namespace.oid = procedure_row.pronamespace
    WHERE namespace.nspname = 'public'
      AND procedure_row.proname = ANY (ARRAY[
        'photo_objet_ack_expected_slot_alert',
        'photo_objet_claim_daily_execution',
        'photo_objet_claim_expected_slot',
        'photo_objet_complete_expected_slot',
        'photo_objet_complete_recovery_slot',
        'photo_objet_due_recovery_slots',
        'photo_objet_ensure_expected_slots',
        'photo_objet_fail_daily_execution',
        'photo_objet_fail_expected_slot',
        'photo_objet_finalize_daily_report',
        'photo_objet_heartbeat_daily_execution',
        'photo_objet_refresh_expected_slot_health',
        'photo_objet_sales_export_runs'
      ])
  LOOP
    EXECUTE format(
      'REVOKE ALL ON FUNCTION %I.%I(%s) FROM PUBLIC, anon, authenticated, service_role',
      v_function.schema_name,
      v_function.function_name,
      v_function.arguments
    );
  END LOOP;
END;
$revoke_retired_collection_rpcs$;

COMMENT ON TABLE public.photo_objet_monitoring_policies IS
  'Historical Photo Objet automatic collection policy ledger. Automatic collection was permanently retired on 2026-09-16; every policy must remain disabled and closed.';
COMMENT ON TABLE public.photo_objet_expected_slots IS
  'Historical Photo Objet scheduler evidence. No new slots are materialized after automatic collection retirement on 2026-09-16.';
COMMENT ON TABLE public.photo_objet_sales_pull_runs IS
  'Photo sales import ledger. Automatic runs are permanently retired; new rows must come from the explicit Super Admin Excel import with run_source=manual.';
COMMENT ON FUNCTION public.reject_photo_objet_collection_reactivation() IS
  'Blocks reactivation of the permanently retired Photo Objet automatic sales collector.';
COMMENT ON FUNCTION public.reject_photo_objet_automatic_sales_run() IS
  'Rejects every new Photo sales run except the explicit Super Admin Excel import.';

DO $verify_retirement$
DECLARE
  v_function regprocedure;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.photo_objet_monitoring_policies
    WHERE is_enabled OR effective_to IS NULL
  ) THEN
    RAISE EXCEPTION 'PHOTO_OBJET_COLLECTION_RETIREMENT_POLICY_VERIFY_FAILED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM cron.job
    WHERE jobname = 'photo-objet-materialize-expected-slots'
  ) THEN
    RAISE EXCEPTION 'PHOTO_OBJET_COLLECTION_RETIREMENT_CRON_VERIFY_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid = 'public.photo_objet_monitoring_policies'::regclass
      AND trigger_row.tgname = 'trg_reject_photo_objet_collection_reactivation'
      AND trigger_row.tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'PHOTO_OBJET_COLLECTION_RETIREMENT_TRIGGER_VERIFY_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid = 'public.photo_objet_sales_pull_runs'::regclass
      AND trigger_row.tgname = 'trg_reject_photo_objet_automatic_sales_run'
      AND trigger_row.tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'PHOTO_OBJET_COLLECTION_RETIREMENT_RUN_TRIGGER_VERIFY_FAILED';
  END IF;

  IF has_table_privilege('service_role', 'public.photo_objet_expected_slots', 'INSERT')
     OR has_table_privilege('service_role', 'public.photo_objet_sales_pull_runs', 'INSERT')
     OR has_table_privilege('service_role', 'public.photo_objet_sales_raw', 'INSERT') THEN
    RAISE EXCEPTION 'PHOTO_OBJET_COLLECTION_RETIREMENT_TABLE_GRANT_VERIFY_FAILED';
  END IF;

  FOR v_function IN
    SELECT procedure_row.oid::regprocedure
    FROM pg_proc procedure_row
    JOIN pg_namespace namespace ON namespace.oid = procedure_row.pronamespace
    WHERE namespace.nspname = 'public'
      AND procedure_row.proname = ANY (ARRAY[
        'photo_objet_ack_expected_slot_alert',
        'photo_objet_claim_daily_execution',
        'photo_objet_claim_expected_slot',
        'photo_objet_complete_expected_slot',
        'photo_objet_complete_recovery_slot',
        'photo_objet_due_recovery_slots',
        'photo_objet_ensure_expected_slots',
        'photo_objet_fail_daily_execution',
        'photo_objet_fail_expected_slot',
        'photo_objet_finalize_daily_report',
        'photo_objet_heartbeat_daily_execution',
        'photo_objet_refresh_expected_slot_health',
        'photo_objet_sales_export_runs'
      ])
  LOOP
    IF has_function_privilege('anon', v_function, 'EXECUTE')
       OR has_function_privilege('authenticated', v_function, 'EXECUTE')
       OR has_function_privilege('service_role', v_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'PHOTO_OBJET_COLLECTION_RETIREMENT_RPC_VERIFY_FAILED: %',
        v_function;
    END IF;
  END LOOP;
END;
$verify_retirement$;

COMMIT;
