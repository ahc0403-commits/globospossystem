\set ON_ERROR_STOP on
DO $verify$
DECLARE v_definition text;
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.direct_order_request_addresses'::regclass
      AND attname IN ('latitude', 'longitude') AND attnotnull
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.direct_order_request_addresses'::regclass
      AND conname = 'direct_order_address_location_mode_valid' AND convalidated
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_MANUAL_ADDRESS_SCHEMA_INVALID';
  END IF;
  SELECT pg_get_functiondef('public.direct_order_public_submit(uuid,text,uuid,jsonb)'::regprocedure)
    INTO v_definition;
  IF position('address_source'' = ''manual''' IN v_definition) = 0
     OR position('direct_order_validate_session' IN v_definition) = 0
     OR position('DIRECT_ORDER_OUTSIDE_HOURS' IN v_definition) = 0
     OR position('v_storefront.ordering_hours_enforced' IN v_definition) = 0
     OR position('idempotent' IN v_definition) = 0
     OR has_function_privilege('anon', 'public.direct_order_public_submit(uuid,text,uuid,jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.direct_order_public_submit(uuid,text,uuid,jsonb)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.direct_order_public_submit(uuid,text,uuid,jsonb)', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'DIRECT_ORDER_MANUAL_ADDRESS_RPC_INVALID';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class
    WHERE oid = 'public.direct_order_request_addresses'::regclass) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_RLS_DISABLED';
  END IF;
END;
$verify$;
SELECT 'DIRECT_DELIVERY_MANUAL_ADDRESSES_VERIFY_PASS' AS result;
