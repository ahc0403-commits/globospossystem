\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_close regprocedure := to_regprocedure(
    'public.run_scheduled_daily_closings(date)'
  );
  v_upsert regprocedure := to_regprocedure(
    'public.upsert_store_promotion(uuid,uuid,text,numeric,timestamp with time zone,timestamp with time zone,boolean)'
  );
  v_sync regprocedure := to_regprocedure(
    'public.sync_active_order_promotion(uuid,uuid,timestamp with time zone)'
  );
  v_refresh regprocedure := to_regprocedure(
    'public.refresh_store_order_promotions(uuid,timestamp with time zone)'
  );
  v_close_definition text;
  v_qr_definition text;
BEGIN
  IF to_regclass('public.store_promotions') IS NULL
     OR v_close IS NULL OR v_upsert IS NULL OR v_sync IS NULL OR v_refresh IS NULL THEN
    RAISE EXCEPTION 'SCHEDULED_CLOSING_PROMOTION_OBJECT_MISSING';
  END IF;

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

  SELECT lower(pg_get_functiondef(v_close)) INTO v_close_definition;
  SELECT lower(pg_get_functiondef(to_regprocedure('public.qr_get_menu(text)'))
    INTO v_qr_definition;

  IF v_close_definition NOT LIKE '%asia/ho_chi_minh%'
     OR v_close_definition NOT LIKE '%inventory_snapshot%'
     OR v_close_definition NOT LIKE '%on conflict (restaurant_id, closing_date) do nothing%'
     OR v_qr_definition NOT LIKE '%promotion_discount_percent%'
     OR v_qr_definition NOT LIKE '%original_price%' THEN
    RAISE EXCEPTION 'SCHEDULED_CLOSING_PROMOTION_FUNCTION_INVALID';
  END IF;

  IF has_function_privilege('anon', v_close, 'EXECUTE')
     OR has_function_privilege('authenticated', v_close, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_close, 'EXECUTE')
     OR has_function_privilege('anon', v_upsert, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_upsert, 'EXECUTE')
     OR has_function_privilege('anon', v_refresh, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_refresh, 'EXECUTE') THEN
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

  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
     AND NOT EXISTS (
       SELECT 1 FROM cron.job
       WHERE jobname = 'daily-closing-2300-hcm'
         AND schedule = '0 16 * * *'
         AND command LIKE '%run_scheduled_daily_closings%'
     ) THEN
    RAISE EXCEPTION 'DAILY_CLOSING_CRON_INVALID';
  END IF;
END
$verify$;

SELECT 'scheduled closing and promotions verification passed' AS result;
