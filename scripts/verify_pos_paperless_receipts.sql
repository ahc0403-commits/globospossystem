\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_definition text;
BEGIN
  IF to_regclass('public.restaurants') IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'restaurants'
         AND column_name = 'id'
     ) OR NOT EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'restaurants'
         AND column_name = 'name'
     ) OR NOT EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'restaurants'
         AND column_name = 'address'
     ) OR NOT EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'restaurants'
         AND column_name = 'is_active'
     ) THEN
    RAISE EXCEPTION 'OFFICE_RESTAURANTS_CONTRACT_BROKEN';
  END IF;

  IF to_regclass('public.digital_receipts') IS NULL
     OR to_regclass('public.digital_receipt_links') IS NULL
     OR to_regclass('public.digital_receipt_access_limits') IS NULL
     OR to_regclass('public.fulfillment_mode_changes') IS NULL THEN
    RAISE EXCEPTION 'PAPERLESS_RECEIPT_TABLE_MISSING';
  END IF;

  IF to_regprocedure(
       'public.super_admin_set_fulfillment_mode(uuid,text,text,uuid)'
     ) IS NULL
     OR to_regprocedure('public.ensure_digital_receipt(uuid,numeric,numeric)') IS NULL
     OR to_regprocedure('public.issue_digital_receipt_link(uuid)') IS NULL
     OR to_regprocedure('public.get_public_receipt(text)') IS NULL
     OR to_regprocedure(
       'public.consume_digital_receipt_rate_limit(text)'
     ) IS NULL
     OR to_regprocedure(
       'public.cleanup_digital_receipt_security_state(integer)'
     ) IS NULL
     OR to_regprocedure('public.revoke_digital_receipt(uuid,text)') IS NULL
     OR to_regprocedure(
       'public.show_customer_receipt_display(uuid,uuid,uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'PAPERLESS_RECEIPT_RPC_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.emergency_hold_print_job()'::regprocedure
  ) INTO v_definition;
  IF position('PAPERLESS_DIGITAL_ROUTING' IN v_definition) = 0
     OR position('copy_type = ''receipt''' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'PAPERLESS_PRINT_ROUTING_UNSAFE';
  END IF;

  SELECT pg_get_functiondef(
    'public.get_public_receipt(text)'::regprocedure
  ) INTO v_definition;
  IF position('digest(p_token' IN v_definition) = 0
     OR position('link.expires_at > now()' IN v_definition) = 0
     OR position(
       'last_presented_at < now() - interval ''1 day''' IN v_definition
     ) = 0
     OR has_table_privilege('anon', 'public.digital_receipts', 'SELECT')
     OR has_table_privilege('anon', 'public.digital_receipt_links', 'SELECT')
     OR has_table_privilege(
       'anon', 'public.digital_receipt_access_limits', 'SELECT'
     )
     OR has_table_privilege(
       'authenticated', 'public.digital_receipt_links', 'SELECT'
     )
     OR has_function_privilege(
       'anon', 'public.get_public_receipt(text)', 'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated', 'public.get_public_receipt(text)', 'EXECUTE'
     )
     OR NOT has_function_privilege(
       'service_role', 'public.get_public_receipt(text)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_PUBLIC_BOUNDARY_UNSAFE';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'digital_receipt_links'
      AND column_name = 'expires_at'
  ) THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_EXPIRY_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.issue_digital_receipt_link(uuid)'::regprocedure
  ) INTO v_definition;
  IF position('OFFSET 2' IN v_definition) = 0
     OR position('FOR UPDATE' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_ACTIVE_LINK_CAP_UNSAFE';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.restaurant_settings
    WHERE fulfillment_mode NOT IN ('pos_print', 'paperless')
  ) OR EXISTS (
    SELECT 1 FROM public.orders
    WHERE fulfillment_mode_snapshot NOT IN ('pos_print', 'paperless')
  ) OR EXISTS (
    SELECT 1 FROM public.order_items
    WHERE fulfillment_mode_snapshot NOT IN ('pos_print', 'paperless')
  ) THEN
    RAISE EXCEPTION 'FULFILLMENT_MODE_DATA_INVALID';
  END IF;
END;
$verify$;

SELECT 'PAPERLESS_RECEIPT_VERIFY_OK' AS result;
