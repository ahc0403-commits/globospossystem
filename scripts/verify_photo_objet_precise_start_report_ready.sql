\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_table_writes integer;
BEGIN
  IF to_regclass('public.photo_objet_daily_executions') IS NULL
     OR to_regprocedure('public.photo_objet_claim_daily_execution(date,time without time zone,text,text)') IS NULL
     OR to_regprocedure('public.photo_objet_heartbeat_daily_execution(date,time without time zone,text)') IS NULL
     OR to_regprocedure('public.photo_objet_fail_daily_execution(date,time without time zone,text,text)') IS NULL
     OR to_regprocedure('public.photo_objet_finalize_daily_report(date,time without time zone,text)') IS NULL
     OR to_regprocedure('public.photo_objet_daily_report_is_ready(date)') IS NULL
     OR to_regprocedure('public.photo_objet_sales_export_runs(date)') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_PRECISE_START_OBJECT_MISSING';
  END IF;

  SELECT count(*) INTO v_table_writes
  FROM (VALUES ('anon'), ('authenticated')) roles(role_name)
  WHERE has_table_privilege(
    roles.role_name,
    'public.photo_objet_daily_executions',
    'INSERT,UPDATE,DELETE'
  );
  IF v_table_writes <> 0 THEN
    RAISE EXCEPTION 'PHOTO_PRECISE_START_TABLE_WRITE_TOO_BROAD';
  END IF;
  IF has_function_privilege(
       'authenticated',
       'public.photo_objet_claim_daily_execution(date,time without time zone,text,text)',
       'EXECUTE'
     ) OR NOT has_function_privilege(
       'service_role',
       'public.photo_objet_finalize_daily_report(date,time without time zone,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PHOTO_PRECISE_START_RPC_PRIVILEGE_INVALID';
  END IF;
  IF NOT has_function_privilege(
       'authenticated', 'public.photo_objet_sales_export_runs(date)', 'EXECUTE'
     ) OR NOT has_function_privilege(
       'authenticated', 'public.photo_objet_daily_report_is_ready(date)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PHOTO_EXPORT_READINESS_RPC_PRIVILEGE_MISSING';
  END IF;
END
$verify$;

SELECT 'Photo Objet precise start/report ready verification passed' AS result;
