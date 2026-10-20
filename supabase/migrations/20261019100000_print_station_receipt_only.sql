BEGIN;
-- production-gate: self-verifying
-- Preserve v3 payload/version/retry/hold rules. Filter before LIMIT and locking:
-- filtering an RPC response would already have claimed operational jobs.
DO $receipt_claim$
DECLARE definition text;
BEGIN
  SELECT pg_get_functiondef('public.claim_print_jobs_v3(uuid,integer)'::regprocedure)
    INTO definition;
  IF strpos(definition, 'AND emergency_held_at IS NULL') = 0
     OR strpos(definition, 'RETURN QUERY') = 0
     OR strpos(definition, 'FOR UPDATE SKIP LOCKED') = 0
     OR strpos(definition, 'print_routing_actor_can_run') = 0 THEN
    RAISE EXCEPTION 'PRINT_STATION_RECEIPT_CLAIM_SOURCE_DRIFT';
  END IF;
  definition := replace(definition,
    'public.claim_print_jobs_v3(', 'public.claim_print_station_receipt_jobs(');
  definition := replace(definition, 'RETURN QUERY',
    'IF p_limit = 0 THEN RETURN; END IF; RETURN QUERY');
  definition := replace(definition, 'AND emergency_held_at IS NULL',
    $predicate$AND emergency_held_at IS NULL
      AND destination_id IN (
        SELECT destination.id FROM public.printer_destinations destination
        WHERE destination.restaurant_id = p_store_id
          AND destination.purpose = 'receipt' AND destination.is_active = true
      )$predicate$);
  EXECUTE definition;
END;
$receipt_claim$;
REVOKE ALL ON FUNCTION public.claim_print_station_receipt_jobs(uuid,integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_print_station_receipt_jobs(uuid,integer)
  TO authenticated, service_role;
DO $verify$
BEGIN
  IF has_function_privilege('anon',
      'public.claim_print_station_receipt_jobs(uuid,integer)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated',
      'public.claim_print_station_receipt_jobs(uuid,integer)', 'EXECUTE')
     OR strpos(pg_get_functiondef(
       'public.claim_print_station_receipt_jobs(uuid,integer)'::regprocedure),
       'destination.purpose = ''receipt''') = 0 THEN
    RAISE EXCEPTION 'PRINT_STATION_RECEIPT_CLAIM_VERIFY_FAILED';
  END IF;
END;
$verify$;
NOTIFY pgrst, 'reload schema';
COMMIT;
