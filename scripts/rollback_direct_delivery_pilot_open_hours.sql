\set ON_ERROR_STOP on

-- Re-enable each storefront's configured direct-delivery ordering window.
BEGIN;

UPDATE public.direct_order_storefronts
SET ordering_hours_enforced = true,
    updated_at = now()
WHERE ordering_hours_enforced = false;

DO $rollback$
DECLARE
  v_approve regprocedure := to_regprocedure(
    'public.direct_order_approve_payment(uuid,uuid,numeric,text)'
  );
  v_definition text;
  v_pilot_gate constant text := $old$
  -- Direct delivery is routed through its isolated fulfillment ticket graph.
  -- Keep its financial order snapshots on pos_print so a paperless dine-in
  -- workflow cannot intercept or duplicate the delivery ticket.$old$;
  v_original_gate constant text := $new$
  IF v_mode <> 'pos_print' THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUIRES_POS_PRINT';
  END IF;$new$;
  v_occurrences integer;
BEGIN
  IF v_approve IS NULL THEN
    RAISE EXCEPTION
      'PILOT_OPEN_HOURS_ROLLBACK_FAILED: approval function missing';
  END IF;

  SELECT pg_get_functiondef(v_approve::oid) INTO v_definition;
  v_occurrences := (
    length(v_definition) - length(replace(v_definition, v_pilot_gate, ''))
  ) / length(v_pilot_gate);
  IF v_occurrences <> 1 THEN
    RAISE EXCEPTION
      'PILOT_OPEN_HOURS_ROLLBACK_FAILED: approval anchor count %',
      v_occurrences;
  END IF;
  EXECUTE replace(v_definition, v_pilot_gate, v_original_gate);

  SELECT pg_get_functiondef(v_approve::oid) INTO v_definition;
  IF position(v_original_gate IN v_definition) = 0
     OR position(v_pilot_gate IN v_definition) > 0 THEN
    RAISE EXCEPTION
      'PILOT_OPEN_HOURS_ROLLBACK_FAILED: approval gate not restored';
  END IF;
END;
$rollback$;

DO $verification$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.direct_order_storefronts
    WHERE ordering_hours_enforced = false
  ) THEN
    RAISE EXCEPTION
      'PILOT_OPEN_HOURS_ROLLBACK_FAILED';
  END IF;
END;
$verification$;

COMMIT;

SELECT 'DIRECT_DELIVERY_PILOT_HOURS_ROLLBACK_READY' AS result;
