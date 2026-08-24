\set ON_ERROR_STOP on

BEGIN;

DO $rollback$
DECLARE
  v_approve regprocedure := to_regprocedure(
    'public.direct_order_approve_payment(uuid,uuid,numeric,text)'
  );
  v_definition text;
  v_occurrences integer;
  v_pilot_emergency_gate constant text := $pilot$
  -- Direct delivery uses its own fulfillment ticket graph, so an active
  -- paperless emergency session cannot intercept or duplicate this ticket.
$pilot$;
  v_original_emergency_gate constant text := $original$
  IF EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_sessions session_row
    WHERE session_row.restaurant_id = p_store_id
      AND session_row.status = 'active'
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_EMERGENCY_ACTIVE';
  END IF;
$original$;
  v_pilot_quote_gate constant text := $pilot$
  -- Uploading payment proof locks the quoted amount. The locked quote remains
  -- approvable after its browsing TTL because amount, proof, and menu integrity
  -- are all revalidated below before the atomic payment is created.
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_EXPIRED';
  END IF;
$pilot$;
  v_original_quote_gate constant text := $original$
  IF NOT FOUND OR v_quote.expires_at <= now() THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_EXPIRED';
  END IF;
$original$;
BEGIN
  IF v_approve IS NULL THEN
    RAISE EXCEPTION 'PILOT_ACTIONS_ROLLBACK_FAILED: approval function missing';
  END IF;

  SELECT pg_get_functiondef(v_approve::oid) INTO v_definition;
  v_occurrences := (
    length(v_definition) - length(replace(v_definition, v_pilot_emergency_gate, ''))
  ) / length(v_pilot_emergency_gate);
  IF v_occurrences <> 1 THEN
    RAISE EXCEPTION
      'PILOT_ACTIONS_ROLLBACK_FAILED: emergency anchor count %',
      v_occurrences;
  END IF;
  v_definition := replace(
    v_definition,
    v_pilot_emergency_gate,
    v_original_emergency_gate
  );

  v_occurrences := (
    length(v_definition) - length(replace(v_definition, v_pilot_quote_gate, ''))
  ) / length(v_pilot_quote_gate);
  IF v_occurrences <> 1 THEN
    RAISE EXCEPTION
      'PILOT_ACTIONS_ROLLBACK_FAILED: quote anchor count %',
      v_occurrences;
  END IF;
  EXECUTE replace(v_definition, v_pilot_quote_gate, v_original_quote_gate);
END;
$rollback$;

COMMIT;
