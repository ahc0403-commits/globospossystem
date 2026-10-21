BEGIN;
-- production-gate: self-verifying
-- Owner decision 2026-10-21: actual sales remain reportable at any time.
-- A scheduler result is audit history, not the owner's reporting decision.
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='120s';

DO $patch$
DECLARE d text; a integer; b integer;
  gate text := ' IF EXISTS(SELECT 1 FROM public.restaurant_daily_sales_finalizations WHERE business_date=p_business_date AND status<>''finalized'') THEN RAISE EXCEPTION ''RESTAURANT_EXPORT_DATA_INTEGRITY_FAILED''; END IF;';
BEGIN
  SELECT pg_get_functiondef('public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer)'::regprocedure) INTO d;
  IF strpos(d,'OWNER_CONTROLLED_SALES_REPORTING')=0 THEN
    IF (length(d)-length(replace(d,gate,'')))/length(gate)<>1 THEN
      RAISE EXCEPTION 'OWNER_SALES_PAGE_ANCHOR_CHANGED';
    END IF;
    EXECUTE replace(d,gate,' -- OWNER_CONTROLLED_SALES_REPORTING: scheduled results do not gate source sales.');
  END IF;

  SELECT pg_get_functiondef('public.get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure) INTO d;
  IF strpos(d,'OWNER_CONTROLLED_SALES_REPORTING')=0 THEN
    a:=strpos(d,E'  SELECT * INTO v_finalization\n');
    b:=strpos(d,'  v_start := p_business_date::timestamp');
    IF a=0 OR b<=a OR strpos(substr(d,a,b-a),'v_finalization.status')=0
       OR strpos(substr(d,a,b-a),'v_report_status := CASE')=0 THEN
      RAISE EXCEPTION 'OWNER_SALES_GROUPED_ANCHOR_CHANGED';
    END IF;
    EXECUTE substr(d,1,a-1)||E'  -- OWNER_CONTROLLED_SALES_REPORTING: ready means downloadable, not owner-finalized.\n  v_report_status := ''ready'';\n'||substr(d,b);
  END IF;
END $patch$;

-- Retain immutable historical results. Do not invent an owner confirmation,
-- rewrite receipts, repair old failures to "finalized", or touch issued data.
DO $schedule$
BEGIN
  IF to_regclass('cron.job') IS NOT NULL THEN
    UPDATE cron.job SET active=false
      WHERE jobname='restaurant-daily-sales-finalize-2220-hcm' AND active;
  END IF;
END $schedule$;
REVOKE ALL ON FUNCTION public.restaurant_finalize_daily_sales(),
  public.restaurant_finalize_daily_sales_at(date,timestamptz)
  FROM PUBLIC,anon,authenticated,service_role;

COMMENT ON FUNCTION public.get_restaurant_daily_sales_exports_by_tax_entity(date) IS
  'Owner-controlled reporting: completed actual sales are available throughout the selected HCM day. Legacy scheduled finalization results do not block reporting or constitute owner confirmation.';
COMMENT ON FUNCTION public.restaurant_finalize_daily_sales() IS
  'Retired automatic sales finalizer. No application-role execute permission; historical results remain immutable audit history.';

DO $verify$
DECLARE d text; signature text;
BEGIN
  FOREACH signature IN ARRAY ARRAY[
    'public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer)',
    'public.get_restaurant_daily_sales_exports_by_tax_entity(date)'
  ] LOOP
    SELECT pg_get_functiondef(signature::regprocedure) INTO d;
    IF strpos(d,'OWNER_CONTROLLED_SALES_REPORTING')=0
       OR strpos(d,'RESTAURANT_EXPORT_DATA_INTEGRITY_FAILED')>0
       OR strpos(d,'v_finalization.status')>0
       OR strpos(d,'is_super_admin()')=0
       OR has_function_privilege('anon',signature,'EXECUTE')
       OR NOT has_function_privilege('authenticated',signature,'EXECUTE') THEN
      RAISE EXCEPTION 'OWNER_SALES_REPORT_VERIFY_FAILED';
    END IF;
  END LOOP;
  IF has_function_privilege('service_role','public.restaurant_finalize_daily_sales()','EXECUTE')
     OR has_function_privilege('authenticated','public.restaurant_finalize_daily_sales_at(date,timestamptz)','EXECUTE') THEN
    RAISE EXCEPTION 'OWNER_SALES_AUTOMATION_PRIVILEGE_DRIFT';
  END IF;
  IF to_regclass('cron.job') IS NOT NULL THEN
    IF EXISTS(SELECT 1 FROM cron.job WHERE jobname='restaurant-daily-sales-finalize-2220-hcm' AND active) THEN
      RAISE EXCEPTION 'OWNER_SALES_SCHEDULE_STILL_ACTIVE';
    END IF;
  END IF;
END $verify$;
COMMIT;
