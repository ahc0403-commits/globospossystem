\set ON_ERROR_STOP on

DO $rollback$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.photo_objet_daily_executions
    WHERE status = 'running'
  ) THEN
    RAISE EXCEPTION 'PHOTO_PRECISE_START_ROLLBACK_ACTIVE_EXECUTION';
  ELSIF EXISTS (SELECT 1 FROM public.photo_objet_daily_executions) THEN
    RAISE EXCEPTION 'PHOTO_PRECISE_START_ROLLBACK_EVIDENCE_PRESENT';
  END IF;
END
$rollback$;

DROP FUNCTION IF EXISTS public.photo_objet_sales_export_runs(date);
DROP FUNCTION IF EXISTS public.photo_objet_daily_report_is_ready(date);
DROP FUNCTION IF EXISTS public.photo_objet_finalize_daily_report(date, time, text);
DROP FUNCTION IF EXISTS public.photo_objet_fail_daily_execution(date, time, text, text);
DROP FUNCTION IF EXISTS public.photo_objet_heartbeat_daily_execution(date, time, text);
DROP FUNCTION IF EXISTS public.photo_objet_claim_daily_execution(date, time, text, text);
DROP TABLE IF EXISTS public.photo_objet_daily_executions;

SELECT 'Photo Objet precise start/report ready rollback passed' AS result;
