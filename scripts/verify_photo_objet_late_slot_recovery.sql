\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_claim_definition text;
  v_heartbeat_definition text;
  v_finalize_definition text;
  v_export_definition text;
BEGIN
  SELECT lower(pg_get_functiondef(
    'public.photo_objet_claim_daily_execution(date,time without time zone,text,text)'::regprocedure
  )) INTO v_claim_definition;
  SELECT lower(pg_get_functiondef(
    'public.photo_objet_heartbeat_daily_execution(date,time without time zone,text)'::regprocedure
  )) INTO v_heartbeat_definition;
  SELECT lower(pg_get_functiondef(
    'public.photo_objet_finalize_daily_report(date,time without time zone,text)'::regprocedure
  )) INTO v_finalize_definition;
  SELECT lower(pg_get_functiondef(
    'public.photo_objet_sales_export_runs(date)'::regprocedure
  )) INTO v_export_definition;

  IF v_claim_definition LIKE '%deadline_exceeded%'
     OR v_claim_definition LIKE '%hard_deadline%'
     OR v_claim_definition NOT LIKE '%v_now < v_scheduled_at%'
     OR v_claim_definition NOT LIKE '%execution.lease_expires_at <= v_now%' THEN
    RAISE EXCEPTION 'PHOTO_LATE_RECOVERY_CLAIM_CONTRACT_INVALID';
  END IF;
  IF v_heartbeat_definition LIKE '%hard_deadline%'
     OR v_heartbeat_definition NOT LIKE '%photo_daily_execution_lease_lost%' THEN
    RAISE EXCEPTION 'PHOTO_LATE_RECOVERY_HEARTBEAT_CONTRACT_INVALID';
  END IF;
  IF v_finalize_definition LIKE '%report_ready_deadline_exceeded%'
     OR v_finalize_definition LIKE '%run.finished_at <%'
     OR v_finalize_definition NOT LIKE '%run.run_source = ''scheduled''%'
     OR v_finalize_definition NOT LIKE '%run.interval_end_at = v_scheduled_at%'
     OR v_finalize_definition NOT LIKE '%v_valid_runs <> v_required_stores%' THEN
    RAISE EXCEPTION 'PHOTO_LATE_RECOVERY_FINALIZE_CONTRACT_INVALID';
  END IF;
  IF v_export_definition LIKE '%run.finished_at <%'
     OR v_export_definition NOT LIKE '%photo_objet_daily_report_is_ready%'
     OR v_export_definition NOT LIKE '%run.run_source = ''scheduled''%' THEN
    RAISE EXCEPTION 'PHOTO_LATE_RECOVERY_EXPORT_CONTRACT_INVALID';
  END IF;

  IF has_function_privilege(
       'authenticated',
       'public.photo_objet_claim_daily_execution(date,time without time zone,text,text)',
       'EXECUTE'
     ) OR NOT has_function_privilege(
       'service_role',
       'public.photo_objet_finalize_daily_report(date,time without time zone,text)',
       'EXECUTE'
     ) OR NOT has_function_privilege(
       'authenticated', 'public.photo_objet_sales_export_runs(date)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PHOTO_LATE_RECOVERY_RPC_PRIVILEGE_INVALID';
  END IF;
END
$verify$;

SELECT 'Photo Objet late slot recovery verification passed' AS result;
