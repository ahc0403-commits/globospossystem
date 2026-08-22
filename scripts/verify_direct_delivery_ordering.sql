\set ON_ERROR_STOP on

-- Production-only, read-only verification. Storefront activation is a later,
-- separately approved operational action and must stay off after deployment.
DO $verify$
DECLARE
  v_table text;
  v_function_count integer;
BEGIN
  FOREACH v_table IN ARRAY ARRAY[
    'direct_order_storefronts',
    'direct_order_sessions',
    'direct_order_public_access_limits',
    'direct_order_requests',
    'direct_order_request_items',
    'direct_order_request_addresses',
    'direct_order_location_facts',
    'direct_order_messages',
    'direct_order_quotes',
    'direct_order_sepay_candidates',
    'direct_order_financials',
    'direct_delivery_fulfillment_tickets',
    'direct_delivery_fulfillment_ticket_items',
    'direct_order_dispatches'
  ] LOOP
    IF to_regclass('public.' || v_table) IS NULL THEN
      RAISE EXCEPTION 'DIRECT_ORDER_TABLE_MISSING:%', v_table;
    END IF;
    IF NOT EXISTS (
      SELECT 1
      FROM pg_class class_row
      JOIN pg_namespace namespace_row
        ON namespace_row.oid = class_row.relnamespace
      WHERE namespace_row.nspname = 'public'
        AND class_row.relname = v_table
        AND class_row.relrowsecurity
    ) THEN
      RAISE EXCEPTION 'DIRECT_ORDER_RLS_DISABLED:%', v_table;
    END IF;
    IF has_table_privilege('anon', 'public.' || v_table, 'SELECT,INSERT,UPDATE,DELETE')
       OR has_table_privilege(
         'authenticated', 'public.' || v_table, 'SELECT,INSERT,UPDATE,DELETE'
       ) THEN
      RAISE EXCEPTION 'DIRECT_ORDER_CLIENT_TABLE_PRIVILEGE_LEAK:%', v_table;
    END IF;
  END LOOP;

  SELECT count(*) INTO v_function_count
  FROM pg_proc procedure_row
  JOIN pg_namespace namespace_row
    ON namespace_row.oid = procedure_row.pronamespace
  WHERE namespace_row.nspname = 'public'
    AND (
      procedure_row.proname LIKE 'direct_order_%'
      OR procedure_row.proname LIKE 'direct_delivery_%'
    );
  IF v_function_count <> 28 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_FUNCTION_COUNT_DRIFT:%', v_function_count;
  END IF;

  IF to_regprocedure(
    'public.direct_order_approve_payment(uuid,uuid,numeric,text)'
  ) IS NULL OR to_regprocedure(
    'public.direct_order_public_submit(uuid,text,uuid,jsonb)'
  ) IS NULL OR to_regprocedure(
    'public.direct_order_analytics(uuid,date,date)'
  ) IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CRITICAL_FUNCTION_MISSING';
  END IF;

  IF has_function_privilege(
    'anon', 'public.direct_order_public_submit(uuid,text,uuid,jsonb)', 'EXECUTE'
  ) OR has_function_privilege(
    'authenticated',
    'public.direct_order_public_submit(uuid,text,uuid,jsonb)',
    'EXECUTE'
  ) OR NOT has_function_privilege(
    'service_role',
    'public.direct_order_public_submit(uuid,text,uuid,jsonb)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PUBLIC_RPC_PRIVILEGE_DRIFT';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM storage.buckets bucket_row
    WHERE bucket_row.id = 'direct-order-proofs'
      AND bucket_row.public = false
      AND bucket_row.file_size_limit = 5242880
      AND bucket_row.allowed_mime_types @>
        ARRAY['image/jpeg', 'image/png', 'image/webp']
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROOF_BUCKET_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.direct_order_storefronts WHERE is_enabled
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_UNEXPECTEDLY_ENABLED';
  END IF;

  IF to_regprocedure('public.process_payment(uuid,uuid,numeric,text)') IS NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_ANCHOR_MISSING';
  END IF;
END;
$verify$;

SELECT 'DIRECT_DELIVERY_ORDERING_VERIFY_PASS' AS result;
