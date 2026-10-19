BEGIN;
-- production-gate: self-verifying
-- The owner requested BunsikClub purchasing parity for every operational ID.
-- Scope by active ordering-account requirements, never by tenant UUID or name.
-- No identities, permissions, stock, historical requests or POs are rewritten.
LOCK TABLE public.procurement_store_policies IN SHARE ROW EXCLUSIVE MODE;

DO $$
BEGIN
  IF (SELECT count(*)
      FROM public.restaurants r
      JOIN public.brands b ON b.id = r.brand_id
      JOIN public.procurement_store_policies p ON p.restaurant_id = r.id
      WHERE b.code = 'bunsikclub' AND r.short_code = 'BT' AND r.is_active
        AND p.enabled AND p.new_requests_enabled AND p.two_stage_required) <> 1 THEN
    RAISE EXCEPTION 'PROCUREMENT_PARITY_REFERENCE_NOT_READY';
  END IF;
END $$;

WITH reference AS MATERIALIZED (
  SELECT p.*
  FROM public.procurement_store_policies p
  JOIN public.restaurants r ON r.id = p.restaurant_id
  JOIN public.brands b ON b.id = r.brand_id
  WHERE b.code = 'bunsikclub' AND r.short_code = 'BT' AND r.is_active
), targets AS MATERIALIZED (
  SELECT r.id, to_jsonb(p) AS previous_state
  FROM public.restaurants r
  LEFT JOIN public.procurement_store_policies p ON p.restaurant_id = r.id
  WHERE r.is_active AND EXISTS (
    SELECT 1 FROM public.store_fixed_account_requirements q
    WHERE q.store_id = r.id AND q.is_active AND q.role = 'inventory_orderer'
  )
), changed AS (
  INSERT INTO public.procurement_store_policies AS current_policy (
    restaurant_id, enabled, high_value_amount, max_price_increase_percent,
    quantity_review_multiplier, stock_freshness_hours,
    three_stage_required, new_requests_enabled, two_stage_required
  )
  SELECT t.id, p.enabled, p.high_value_amount, p.max_price_increase_percent,
    p.quantity_review_multiplier, p.stock_freshness_hours,
    p.three_stage_required, p.new_requests_enabled, p.two_stage_required
  FROM targets t CROSS JOIN reference p
  ON CONFLICT (restaurant_id) DO UPDATE SET
    enabled = EXCLUDED.enabled,
    high_value_amount = EXCLUDED.high_value_amount,
    max_price_increase_percent = EXCLUDED.max_price_increase_percent,
    quantity_review_multiplier = EXCLUDED.quantity_review_multiplier,
    stock_freshness_hours = EXCLUDED.stock_freshness_hours,
    three_stage_required = EXCLUDED.three_stage_required,
    new_requests_enabled = EXCLUDED.new_requests_enabled,
    two_stage_required = EXCLUDED.two_stage_required,
    row_version = current_policy.row_version + 1,
    updated_at = now()
  WHERE (current_policy.enabled, current_policy.high_value_amount,
    current_policy.max_price_increase_percent, current_policy.quantity_review_multiplier,
    current_policy.stock_freshness_hours, current_policy.three_stage_required,
    current_policy.new_requests_enabled, current_policy.two_stage_required)
    IS DISTINCT FROM (EXCLUDED.enabled, EXCLUDED.high_value_amount,
    EXCLUDED.max_price_increase_percent, EXCLUDED.quantity_review_multiplier,
    EXCLUDED.stock_freshness_hours, EXCLUDED.three_stage_required,
    EXCLUDED.new_requests_enabled, EXCLUDED.two_stage_required)
  RETURNING *
)
INSERT INTO public.procurement_events (
  restaurant_id, record_id, action, actor, reason, previous_state, next_state
)
SELECT c.restaurant_id, c.restaurant_id, 'align_procurement_policy',
  '{"system":"migration","subject_id":"20261019081922"}'::jsonb,
  'Owner-requested BunsikClub purchasing parity for all operational IDs',
  t.previous_state, to_jsonb(c)
FROM changed c JOIN targets t ON t.id = c.restaurant_id;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.restaurants r
    LEFT JOIN public.procurement_store_policies p ON p.restaurant_id = r.id
    CROSS JOIN (
      SELECT to_jsonb(p) - ARRAY['restaurant_id', 'row_version', 'updated_at'] AS policy
      FROM public.procurement_store_policies p
      JOIN public.restaurants r ON r.id = p.restaurant_id
      JOIN public.brands b ON b.id = r.brand_id
      WHERE b.code = 'bunsikclub' AND r.short_code = 'BT' AND r.is_active
    ) reference
    WHERE r.is_active AND EXISTS (
      SELECT 1 FROM public.store_fixed_account_requirements q
      WHERE q.store_id = r.id AND q.is_active AND q.role = 'inventory_orderer'
    ) AND (to_jsonb(p) - ARRAY['restaurant_id', 'row_version', 'updated_at'])
      IS DISTINCT FROM reference.policy
  ) THEN
    RAISE EXCEPTION 'PROCUREMENT_PARITY_VERIFICATION_FAILED';
  END IF;
END $$;
COMMIT;
