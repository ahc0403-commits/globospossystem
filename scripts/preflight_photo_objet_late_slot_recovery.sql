\set ON_ERROR_STOP on

DO $preflight$
DECLARE
  v_open_v4 integer;
BEGIN
  IF to_regclass('public.photo_objet_daily_executions') IS NULL
     OR to_regprocedure(
       'public.photo_objet_claim_daily_execution(date,time without time zone,text,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.photo_objet_heartbeat_daily_execution(date,time without time zone,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.photo_objet_finalize_daily_report(date,time without time zone,text)'
     ) IS NULL
     OR to_regprocedure('public.photo_objet_sales_export_runs(date)') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_LATE_RECOVERY_REQUIRED_OBJECT_MISSING';
  END IF;

  SELECT count(*) INTO v_open_v4
  FROM public.photo_objet_monitoring_policies policy
  JOIN public.restaurants store ON store.id = policy.store_id
  WHERE policy.effective_to IS NULL
    AND policy.schedule_version = 'hcm-eod-2200-v4'
    AND policy.is_enabled = true
    AND store.is_active = true;
  IF v_open_v4 <> 6 THEN
    RAISE EXCEPTION 'PHOTO_LATE_RECOVERY_REQUIRES_SIX_ACTIVE_V4_STORES: %',
      v_open_v4;
  END IF;
END
$preflight$;

SELECT 'Photo Objet late slot recovery preflight passed' AS result;
