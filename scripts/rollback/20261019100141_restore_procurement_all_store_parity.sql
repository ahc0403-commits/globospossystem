-- production-gate: self-verifying
-- Run only through deploy_pos_production.sh --migration <this file> --db-only.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';
LOCK TABLE public.procurement_store_policies IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.procurement_role_roster IN SHARE ROW EXCLUSIVE MODE;
CREATE TEMP TABLE parity_restore ON COMMIT DROP AS
SELECT e.* FROM public.procurement_events e
WHERE e.action = 'align_procurement_policy'
  AND e.actor->>'subject_id' = '20261019081922'
  AND NOT EXISTS (
    SELECT 1 FROM public.procurement_events r
    WHERE r.restaurant_id = e.restaurant_id AND r.action = 'restore_procurement_policy'
      AND r.actor->>'subject_id' = '20261019100141' AND r.created_at >= e.created_at
  );
CREATE TEMP TABLE receiver_restore ON COMMIT DROP AS
SELECT e.* FROM public.procurement_events e
WHERE e.action='align_procurement_receiver' AND e.actor->>'subject_id'='20261019081922'
 AND NOT EXISTS(SELECT 1 FROM public.procurement_events r WHERE r.restaurant_id=e.restaurant_id
   AND r.action='restore_procurement_receiver' AND r.actor->>'subject_id'='20261019100141' AND r.created_at>=e.created_at);
DO $$ BEGIN
  IF EXISTS(SELECT 1 FROM receiver_restore e LEFT JOIN public.procurement_role_roster r
    ON r.restaurant_id=e.restaurant_id AND r.system='pos' AND r.stage='verifier'
      AND r.subject_id=(e.next_state->>'subject_id')::uuid
    WHERE to_jsonb(r) IS DISTINCT FROM e.next_state)
  THEN RAISE EXCEPTION 'PROCUREMENT_PARITY_RESTORE_STALE_RECEIVER'; END IF;
  IF EXISTS (
    SELECT 1 FROM parity_restore e
    LEFT JOIN public.procurement_store_policies p ON p.restaurant_id = e.restaurant_id
    WHERE to_jsonb(p) IS DISTINCT FROM e.next_state
  ) THEN RAISE EXCEPTION 'PROCUREMENT_PARITY_RESTORE_STALE_POLICY'; END IF;
  IF EXISTS (
    SELECT 1 FROM parity_restore e
    JOIN public.inventory_purchase_requests r ON r.restaurant_id = e.restaurant_id
    WHERE r.created_at >= e.created_at
  ) OR EXISTS (
    SELECT 1 FROM parity_restore e
    JOIN public.inventory_purchase_orders p ON p.restaurant_id = e.restaurant_id
    WHERE p.created_at >= e.created_at
  ) THEN RAISE EXCEPTION 'PROCUREMENT_PARITY_RESTORE_HAS_NEW_DOCUMENTS'; END IF;
  IF EXISTS(SELECT 1 FROM receiver_restore e JOIN public.inventory_receipts r ON r.restaurant_id=e.restaurant_id
    WHERE r.created_at>=e.created_at OR r.updated_at>=e.created_at)
  THEN RAISE EXCEPTION 'PROCUREMENT_PARITY_RESTORE_HAS_RECEIPT_ACTIVITY'; END IF;
END $$;
DELETE FROM public.procurement_role_roster r USING receiver_restore e
WHERE r.restaurant_id=e.restaurant_id AND r.system='pos' AND r.stage='verifier'
 AND r.subject_id=(e.next_state->>'subject_id')::uuid;
UPDATE public.procurement_store_policies p SET
  enabled = (e.previous_state->>'enabled')::boolean,
  high_value_amount = (e.previous_state->>'high_value_amount')::numeric,
  max_price_increase_percent = (e.previous_state->>'max_price_increase_percent')::numeric,
  quantity_review_multiplier = (e.previous_state->>'quantity_review_multiplier')::numeric,
  stock_freshness_hours = (e.previous_state->>'stock_freshness_hours')::integer,
  three_stage_required = (e.previous_state->>'three_stage_required')::boolean,
  new_requests_enabled = (e.previous_state->>'new_requests_enabled')::boolean,
  two_stage_required = (e.previous_state->>'two_stage_required')::boolean,
  row_version = p.row_version + 1, updated_at = now()
FROM parity_restore e WHERE p.restaurant_id = e.restaurant_id AND e.previous_state IS NOT NULL;
DELETE FROM public.procurement_store_policies p USING parity_restore e
WHERE p.restaurant_id = e.restaurant_id AND e.previous_state IS NULL;
DO $$ BEGIN
  IF EXISTS (
    SELECT 1 FROM parity_restore e
    LEFT JOIN public.procurement_store_policies p ON p.restaurant_id = e.restaurant_id
    WHERE (to_jsonb(p) - ARRAY['row_version', 'updated_at']) IS DISTINCT FROM
      (e.previous_state - ARRAY['row_version', 'updated_at'])
  ) THEN RAISE EXCEPTION 'PROCUREMENT_PARITY_RESTORE_VERIFICATION_FAILED'; END IF;
END $$;
INSERT INTO public.procurement_events(restaurant_id, record_id, action, actor, reason, previous_state, next_state)
SELECT e.restaurant_id, e.restaurant_id, 'restore_procurement_policy',
  '{"system":"migration","subject_id":"20261019100141"}'::jsonb,
  'Restore pre-parity configuration before new purchasing activity',
  e.next_state, (SELECT to_jsonb(p) FROM public.procurement_store_policies p WHERE p.restaurant_id = e.restaurant_id)
FROM parity_restore e;
INSERT INTO public.procurement_events(restaurant_id,record_id,action,actor,reason,previous_state,next_state)
SELECT restaurant_id,restaurant_id,'restore_procurement_receiver',
 '{"system":"migration","subject_id":"20261019100141"}'::jsonb,
 'Restore pre-parity receiver assignment before purchasing activity',next_state,NULL
FROM receiver_restore;
COMMIT;
