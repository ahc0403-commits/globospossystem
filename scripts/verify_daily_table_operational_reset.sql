\set ON_ERROR_STOP on
BEGIN READ ONLY;
DO $$
DECLARE v_name text; v_definition text;
BEGIN
  IF to_regclass('public.order_operational_closures') IS NULL
    OR to_regclass('public.orders_stale_table_operations') IS NULL THEN RAISE EXCEPTION 'RESET_SCHEMA_MISSING'; END IF;
  IF has_function_privilege('anon','public.ensure_store_operational_day(uuid)','EXECUTE')
    OR has_function_privilege('authenticated','public.close_expired_table_operations_at(uuid,timestamptz)','EXECUTE')
    OR has_function_privilege('anon','public.run_daily_table_operational_resets()','EXECUTE')
    OR has_function_privilege('authenticated','public.run_daily_table_operational_resets()','EXECUTE')
    OR has_table_privilege('authenticated','public.order_operational_closures','INSERT') THEN
    RAISE EXCEPTION 'RESET_PRIVILEGE_INVALID';
  END IF;
  FOREACH v_name IN ARRAY ARRAY['public.qr_place_order_pre_takeout_core(text,jsonb,uuid)',
    'public.qr_get_active_order_pre_takeout(text)','public.qr_get_active_order_pre_display_reset(text)'] LOOP
    SELECT pg_get_functiondef(v_name::regprocedure) INTO v_definition;
    IF position('table_order_is_current' IN v_definition)=0 THEN RAISE EXCEPTION 'RESET_QR_SCOPE_MISSING: %',v_name; END IF;
  END LOOP;
  v_name:='public.qr_place_order_before_non_revenue_guard(text,jsonb,uuid,boolean,uuid)';
  SELECT pg_get_functiondef(v_name::regprocedure) INTO v_definition;
  IF position('table_order_is_current' IN v_definition)=0 THEN
    -- Production also has a takeout-availability wrapper with no order
    -- selection of its own. Verify its actual selecting delegate instead.
    IF v_definition ~* '\m(FROM|JOIN)\s+(public\.)?orders\M'
      OR position('RETURN public.qr_place_order_pre_takeout_availability(' IN v_definition)=0
      OR to_regprocedure('public.qr_place_order_pre_takeout_availability(text,jsonb,uuid,boolean,uuid)') IS NULL THEN
      RAISE EXCEPTION 'RESET_QR_SCOPE_MISSING: %',v_name;
    END IF;
    v_name:='public.qr_place_order_pre_takeout_availability(text,jsonb,uuid,boolean,uuid)';
    SELECT pg_get_functiondef(v_name::regprocedure) INTO v_definition;
    IF position('table_order_is_current' IN v_definition)=0 THEN
      RAISE EXCEPTION 'RESET_QR_SCOPE_MISSING: %',v_name;
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM public.order_operational_closures c JOIN public.orders o ON o.id=c.order_id
    WHERE o.operational_closed_at IS DISTINCT FROM c.closed_at OR o.table_id IS DISTINCT FROM c.table_id
      OR (c.closure_kind='unpaid_cancelled' AND o.status<>'cancelled')) THEN
    RAISE EXCEPTION 'RESET_CLOSURE_INTEGRITY_FAILED';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname='cron') THEN
    IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='table-operational-day-reset-0000-hcm'
      AND active AND schedule='*/5 * * * *') THEN RAISE EXCEPTION 'RESET_CRON_MISSING'; END IF;
  END IF;
END;
$$;
COMMIT;
SELECT 'DAILY_TABLE_OPERATIONAL_RESET_VERIFY_OK';
