-- Allow the isolated direct-delivery ticket graph to operate during an active
-- paperless emergency session, and keep a customer-locked payment quote
-- approvable after its pre-payment browsing TTL has elapsed.
-- production-gate: self-verifying

BEGIN;

DO $migration$
DECLARE
  v_approve regprocedure := to_regprocedure(
    'public.direct_order_approve_payment(uuid,uuid,numeric,text)'
  );
  v_definition text;
  v_occurrences integer;
  v_old_emergency_gate constant text := $old$
  IF EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_sessions session_row
    WHERE session_row.restaurant_id = p_store_id
      AND session_row.status = 'active'
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_EMERGENCY_ACTIVE';
  END IF;
$old$;
  v_new_emergency_gate constant text := $new$
  -- Direct delivery uses its own fulfillment ticket graph, so an active
  -- paperless emergency session cannot intercept or duplicate this ticket.
$new$;
  v_old_quote_gate constant text := $old$
  IF NOT FOUND OR v_quote.expires_at <= now() THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_EXPIRED';
  END IF;
$old$;
  v_new_quote_gate constant text := $new$
  -- Uploading payment proof locks the quoted amount. The locked quote remains
  -- approvable after its browsing TTL because amount, proof, and menu integrity
  -- are all revalidated below before the atomic payment is created.
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_EXPIRED';
  END IF;
$new$;
BEGIN
  IF v_approve IS NULL THEN
    RAISE EXCEPTION 'PILOT_ACTIONS_MIGRATION_FAILED: approval function missing';
  END IF;

  SELECT pg_get_functiondef(v_approve::oid) INTO v_definition;
  v_occurrences := (
    length(v_definition) - length(replace(v_definition, v_old_emergency_gate, ''))
  ) / length(v_old_emergency_gate);
  IF v_occurrences <> 1 THEN
    RAISE EXCEPTION
      'PILOT_ACTIONS_MIGRATION_FAILED: emergency gate count %',
      v_occurrences;
  END IF;
  v_definition := replace(
    v_definition,
    v_old_emergency_gate,
    v_new_emergency_gate
  );

  v_occurrences := (
    length(v_definition) - length(replace(v_definition, v_old_quote_gate, ''))
  ) / length(v_old_quote_gate);
  IF v_occurrences <> 1 THEN
    RAISE EXCEPTION
      'PILOT_ACTIONS_MIGRATION_FAILED: quote gate count %',
      v_occurrences;
  END IF;
  EXECUTE replace(v_definition, v_old_quote_gate, v_new_quote_gate);
END;
$migration$;

DO $verification$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.direct_order_approve_payment(uuid,uuid,numeric,text)'::regprocedure
  ) INTO v_definition;

  IF position('DIRECT_ORDER_EMERGENCY_ACTIVE' IN v_definition) > 0
     OR position('v_quote.expires_at <= now()' IN v_definition) > 0
     OR position(
       'Direct delivery uses its own fulfillment ticket graph' IN v_definition
     ) = 0
     OR position(
       'Uploading payment proof locks the quoted amount' IN v_definition
     ) = 0 THEN
    RAISE EXCEPTION
      'PILOT_ACTIONS_MIGRATION_FAILED: approval patch not installed';
  END IF;
END;
$verification$;

COMMIT;
