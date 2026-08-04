\set ON_ERROR_STOP on

DO $verify$
BEGIN
  IF to_regclass('public.store_promotions') IS NULL
     OR to_regprocedure('public.run_scheduled_daily_closings(date)') IS NULL
     OR to_regprocedure(
       'public.upsert_store_promotion(uuid,uuid,text,numeric,timestamp with time zone,timestamp with time zone,boolean)'
     ) IS NULL
     OR to_regprocedure(
       'public.sync_active_order_promotion(uuid,uuid,timestamp with time zone)'
     ) IS NULL
     OR to_regprocedure(
       'public.refresh_store_order_promotions(uuid,timestamp with time zone)'
     ) IS NULL THEN
    RAISE EXCEPTION 'SCHEDULED_CLOSING_PROMOTION_OBJECT_MISSING';
  END IF;
END;
$verify$;

DO $verify$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'daily_closings'
      AND column_name = 'close_source' AND is_nullable = 'NO'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'daily_closings'
      AND column_name = 'inventory_snapshot' AND is_nullable = 'NO'
  ) THEN
    RAISE EXCEPTION 'DAILY_CLOSING_SNAPSHOT_COLUMNS_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE oid = to_regprocedure('public.run_scheduled_daily_closings(date)')
      AND lower(pg_get_functiondef(oid)) LIKE '%asia/ho_chi_minh%'
      AND lower(pg_get_functiondef(oid)) LIKE '%inventory_snapshot%'
      AND lower(pg_get_functiondef(oid)) LIKE
        '%on conflict (restaurant_id, closing_date) do nothing%'
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE oid = to_regprocedure('public.qr_get_menu(text)')
      AND lower(pg_get_functiondef(oid)) LIKE '%promotion_discount_percent%'
      AND lower(pg_get_functiondef(oid)) LIKE '%original_price%'
  ) THEN
    RAISE EXCEPTION 'SCHEDULED_CLOSING_PROMOTION_FUNCTION_INVALID';
  END IF;
END;
$verify$;

DO $verify$
BEGIN
  IF has_function_privilege(
       'anon', 'public.run_scheduled_daily_closings(date)', 'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated', 'public.run_scheduled_daily_closings(date)', 'EXECUTE'
     )
     OR NOT has_function_privilege(
       'service_role', 'public.run_scheduled_daily_closings(date)', 'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.upsert_store_promotion(uuid,uuid,text,numeric,timestamp with time zone,timestamp with time zone,boolean)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.upsert_store_promotion(uuid,uuid,text,numeric,timestamp with time zone,timestamp with time zone,boolean)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.refresh_store_order_promotions(uuid,timestamp with time zone)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.refresh_store_order_promotions(uuid,timestamp with time zone)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'SCHEDULED_CLOSING_PROMOTION_PRIVILEGE_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.order_items'::regclass
      AND tgname = 'trg_sync_order_promotion'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'SCHEDULED_PROMOTION_TRIGGER_MISSING';
  END IF;
END;
$verify$;

DO $verify$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND NOT EXISTS (
       SELECT 1 FROM cron.job
       WHERE jobname = 'daily-closing-2300-hcm'
         AND schedule = '0 16 * * *'
         AND command LIKE '%run_scheduled_daily_closings%'
     ) THEN
    RAISE EXCEPTION 'DAILY_CLOSING_CRON_INVALID';
  END IF;
END;
$verify$;

SELECT 'scheduled closing and promotions verification passed' AS result;
