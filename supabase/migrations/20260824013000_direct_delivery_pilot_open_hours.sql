-- Keep direct-delivery ordering open for the current pilot while retaining a
-- fail-closed per-store switch that can restore the configured hours later.
-- production-gate: self-verifying

BEGIN;

ALTER TABLE public.direct_order_storefronts
  ADD COLUMN IF NOT EXISTS ordering_hours_enforced boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.direct_order_storefronts.ordering_hours_enforced IS
  'When false, direct-delivery submit and payment approval ignore the configured ordering window.';

UPDATE public.direct_order_storefronts
SET ordering_hours_enforced = false,
    updated_at = now()
WHERE ordering_hours_enforced = true;

DO $migration$
DECLARE
  v_submit regprocedure := to_regprocedure(
    'public.direct_order_public_submit(uuid,text,uuid,jsonb)'
  );
  v_approve regprocedure := to_regprocedure(
    'public.direct_order_approve_payment(uuid,uuid,numeric,text)'
  );
  v_definition text;
  v_old_submit constant text := $old$
  IF v_local_time < v_storefront.ordering_starts_at
     OR v_local_time >= v_storefront.ordering_cutoff_at THEN$old$;
  v_new_submit constant text := $new$
  IF v_storefront.ordering_hours_enforced
     AND (v_local_time < v_storefront.ordering_starts_at
          OR v_local_time >= v_storefront.ordering_cutoff_at) THEN$new$;
  v_old_approve constant text := $old$
  IF v_local_time >= LEAST(v_storefront.ordering_cutoff_at, '21:30'::time) THEN$old$;
  v_new_approve constant text := $new$
  IF v_storefront.ordering_hours_enforced
     AND v_local_time >= LEAST(v_storefront.ordering_cutoff_at, '21:30'::time) THEN$new$;
  v_old_mode_gate constant text := $old$
  IF v_mode <> 'pos_print' THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUIRES_POS_PRINT';
  END IF;$old$;
  v_new_mode_gate constant text := $new$
  -- Direct delivery is routed through its isolated fulfillment ticket graph.
  -- Keep its financial order snapshots on pos_print so a paperless dine-in
  -- workflow cannot intercept or duplicate the delivery ticket.$new$;
  v_occurrences integer;
BEGIN
  IF v_submit IS NULL OR v_approve IS NULL THEN
    RAISE EXCEPTION
      'PILOT_OPEN_HOURS_MIGRATION_FAILED: required function missing';
  END IF;

  SELECT pg_get_functiondef(v_submit::oid) INTO v_definition;
  v_occurrences := (
    length(v_definition) - length(replace(v_definition, v_old_submit, ''))
  ) / length(v_old_submit);
  IF v_occurrences <> 1 THEN
    RAISE EXCEPTION
      'PILOT_OPEN_HOURS_MIGRATION_FAILED: submit anchor count %',
      v_occurrences;
  END IF;
  EXECUTE replace(v_definition, v_old_submit, v_new_submit);

  SELECT pg_get_functiondef(v_approve::oid) INTO v_definition;
  v_occurrences := (
    length(v_definition) - length(replace(v_definition, v_old_approve, ''))
  ) / length(v_old_approve);
  IF v_occurrences <> 1 THEN
    RAISE EXCEPTION
      'PILOT_OPEN_HOURS_MIGRATION_FAILED: approval anchor count %',
      v_occurrences;
  END IF;
  EXECUTE replace(v_definition, v_old_approve, v_new_approve);

  SELECT pg_get_functiondef(v_approve::oid) INTO v_definition;
  v_occurrences := (
    length(v_definition) - length(replace(v_definition, v_old_mode_gate, ''))
  ) / length(v_old_mode_gate);
  IF v_occurrences <> 1 THEN
    RAISE EXCEPTION
      'PILOT_OPEN_HOURS_MIGRATION_FAILED: fulfillment gate anchor count %',
      v_occurrences;
  END IF;
  EXECUTE replace(v_definition, v_old_mode_gate, v_new_mode_gate);

  SELECT pg_get_functiondef(v_submit::oid) INTO v_definition;
  IF position(v_new_submit IN v_definition) = 0
     OR position(v_old_submit IN v_definition) > 0 THEN
    RAISE EXCEPTION
      'PILOT_OPEN_HOURS_MIGRATION_FAILED: submit bypass not installed';
  END IF;

  SELECT pg_get_functiondef(v_approve::oid) INTO v_definition;
  IF position(v_new_approve IN v_definition) = 0
     OR position(v_old_approve IN v_definition) > 0
     OR position(v_new_mode_gate IN v_definition) = 0
     OR position(v_old_mode_gate IN v_definition) > 0 THEN
    RAISE EXCEPTION
      'PILOT_OPEN_HOURS_MIGRATION_FAILED: approval pilot patch not installed';
  END IF;
END;
$migration$;

DO $verification$
DECLARE
  v_default text;
BEGIN
  SELECT column_default
  INTO v_default
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'direct_order_storefronts'
    AND column_name = 'ordering_hours_enforced'
    AND data_type = 'boolean'
    AND is_nullable = 'NO';

  IF v_default IS NULL OR lower(v_default) NOT IN ('true', 'true::boolean') THEN
    RAISE EXCEPTION
      'PILOT_OPEN_HOURS_MIGRATION_FAILED: invalid switch column';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.direct_order_storefronts
    WHERE ordering_hours_enforced = true
  ) THEN
    RAISE EXCEPTION
      'PILOT_OPEN_HOURS_MIGRATION_FAILED: existing storefront still enforces hours';
  END IF;
END;
$verification$;

COMMIT;
