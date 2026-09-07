\set ON_ERROR_STOP on
-- Read-only preflight. Existing paid orders, addresses and locations stay intact.
DO $preflight$
DECLARE v_definition text;
BEGIN
  -- Reject a drifted live RPC rather than overwriting unrelated hotfixes.
  -- Digest includes the 20260824013000 per-store ordering-hours switch.
  IF (SELECT md5(prosrc) FROM pg_proc
      WHERE oid = 'public.direct_order_public_submit(uuid,text,uuid,jsonb)'::regprocedure)
      <> 'd828a4dd65b18e5676f9ac04231a3a14' THEN
    RAISE EXCEPTION 'DIRECT_ORDER_SUBMIT_SOURCE_DRIFT';
  END IF;
  SELECT pg_get_functiondef('public.direct_order_public_submit(uuid,text,uuid,jsonb)'::regprocedure)
    INTO v_definition;
  IF position('location_verified' IN v_definition) = 0
     OR position('direct_order_validate_session' IN v_definition) = 0
     OR position('client_request_id' IN v_definition) = 0
     OR position('direct_order_location_facts' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_SUBMIT_PREDECESSOR_UNEXPECTED';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.direct_order_request_addresses'::regclass
      AND conname = 'direct_order_request_addresses_address_source_check'
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_PREDECESSOR_UNEXPECTED';
  END IF;
END;
$preflight$;
