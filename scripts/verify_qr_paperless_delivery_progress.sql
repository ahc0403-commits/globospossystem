\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_function regprocedure := to_regprocedure(
    'public.qr_get_active_order(text)'
  );
  v_definition text;
  v_security_definer boolean;
  v_volatility "char";
  v_config text[];
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION 'QR_PAPERLESS_PROGRESS_VERIFY_FUNCTION_MISSING';
  END IF;

  SELECT pg_get_functiondef(p.oid), p.prosecdef, p.provolatile, p.proconfig
  INTO v_definition, v_security_definer, v_volatility, v_config
  FROM pg_proc p
  WHERE p.oid = v_function;

  IF NOT v_security_definer
     OR v_volatility <> 's'
     OR NOT ('search_path=public, pg_catalog' = ANY(
       COALESCE(v_config, ARRAY[]::text[])
     )) THEN
    RAISE EXCEPTION 'QR_PAPERLESS_PROGRESS_VERIFY_SECURITY_INVALID';
  END IF;

  IF position('WHERE q.token = v_token' IN v_definition) = 0
     OR position('AND q.is_active = true' IN v_definition) = 0
     OR position('v_order.fulfillment_mode_snapshot = ''paperless''' IN v_definition) = 0
     OR position('item.floor_served_quantity' IN v_definition) = 0
     OR position('item.order_item_id = oi.id' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'QR_PAPERLESS_PROGRESS_VERIFY_CONTRACT_INVALID';
  END IF;

  IF NOT has_function_privilege(
       'anon', 'public.qr_get_active_order(text)', 'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated', 'public.qr_get_active_order(text)', 'EXECUTE'
     )
     OR NOT has_function_privilege(
       'service_role', 'public.qr_get_active_order(text)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'QR_PAPERLESS_PROGRESS_VERIFY_GRANT_INVALID';
  END IF;
END;
$verify$;

SELECT 'QR_PAPERLESS_PROGRESS_VERIFY_OK' AS result;
