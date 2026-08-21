\set ON_ERROR_STOP on

-- Read-only verification: cashier catch-up RPC plus one INSERT-only,
-- payload-free event trigger. No existing alert trigger is changed.
DO $verify$
DECLARE
  v_trigger_definition text;
BEGIN
  IF to_regprocedure(
    'public.direct_order_arrival_alerts_after(uuid,timestamp with time zone,uuid,integer)'
  ) IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ARRIVAL_RPC_MISSING';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.direct_order_arrival_alerts_after(uuid,timestamp with time zone,uuid,integer)',
    'EXECUTE'
  ) OR NOT has_function_privilege(
    'authenticated',
    'public.direct_order_arrival_alerts_after(uuid,timestamp with time zone,uuid,integer)',
    'EXECUTE'
  ) OR NOT has_function_privilege(
    'service_role',
    'public.direct_order_arrival_alerts_after(uuid,timestamp with time zone,uuid,integer)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ARRIVAL_RPC_PRIVILEGE_DRIFT';
  END IF;

  SELECT pg_get_triggerdef(trigger_row.oid)
  INTO v_trigger_definition
  FROM pg_trigger trigger_row
  WHERE trigger_row.tgrelid = 'public.direct_order_requests'::regclass
    AND trigger_row.tgname = 'direct_order_arrival_live_event'
    AND NOT trigger_row.tgisinternal;

  IF v_trigger_definition IS NULL
     OR v_trigger_definition NOT LIKE '%AFTER INSERT%'
     OR v_trigger_definition LIKE '%UPDATE%'
     OR v_trigger_definition LIKE '%DELETE%'
     OR v_trigger_definition NOT LIKE '%emit_pos_live_event(''direct_orders''%'
  THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ARRIVAL_TRIGGER_DRIFT:%',
      coalesce(v_trigger_definition, 'missing');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.direct_order_storefronts WHERE is_enabled
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_UNEXPECTEDLY_ENABLED';
  END IF;
END;
$verify$;

SELECT 'DIRECT_DELIVERY_ARRIVAL_ALERT_VERIFY_PASS' AS result;
