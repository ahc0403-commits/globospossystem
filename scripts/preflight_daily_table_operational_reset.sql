\set ON_ERROR_STOP on
BEGIN READ ONLY;
DO $$
DECLARE v_name text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY['orders','order_items','payments','tables','restaurants',
    'emergency_fulfillment_items','emergency_combo_component_items','emergency_floor_direct_items',
    'emergency_floor_ready_lots','leftover_packaging_requests','print_jobs','audit_logs','customer_payment_displays'] LOOP
    IF to_regclass('public.'||v_name) IS NULL THEN RAISE EXCEPTION 'RESET_DEPENDENCY_MISSING: %',v_name; END IF;
  END LOOP;
  FOREACH v_name IN ARRAY ARRAY['public.create_order(uuid,uuid,jsonb)',
    'public.create_buffet_order(uuid,uuid,integer,jsonb)','public.qr_get_active_order(text)',
    'public.qr_place_order(text,jsonb,uuid,boolean,uuid)',
    'public.qr_place_order_pre_takeout_core(text,jsonb,uuid)',
    'public.recalc_order_status(uuid)','public.cancel_order(uuid,uuid,boolean)',
    'public.create_order_with_client_mutation_id(uuid,uuid,jsonb,text)'] LOOP
    IF to_regprocedure(v_name) IS NULL THEN RAISE EXCEPTION 'RESET_RPC_MISSING: %',v_name; END IF;
  END LOOP;
  IF to_regclass('public.order_operational_closures') IS NOT NULL THEN RAISE EXCEPTION 'RESET_ALREADY_INSTALLED'; END IF;
  IF (SELECT count(*) FROM public.restaurants WHERE name='BunsikClub Binh Thanh' AND is_active)<>1 THEN
    RAISE EXCEPTION 'BUNSIK_RESET_STORE_IDENTITY_AMBIGUOUS'; END IF;
END;
$$;
COMMIT;
SELECT 'DAILY_TABLE_OPERATIONAL_RESET_PREFLIGHT_OK';
