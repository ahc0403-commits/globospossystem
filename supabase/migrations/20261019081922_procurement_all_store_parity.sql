BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';
-- production-gate: self-verifying
-- The owner requested BunsikClub purchasing parity for every operational ID.
-- Scope by active ordering-account requirements, never by tenant UUID or name.
-- No identities, permissions, stock, historical requests or POs are rewritten.
LOCK TABLE public.procurement_store_policies IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.procurement_role_roster IN SHARE ROW EXCLUSIVE MODE;

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

-- Match the reference's combined receiving assignment for existing native
-- shared receivers. This never provisions an identity or widens store scope.
WITH eligible AS MATERIALIZED (
  SELECT receiver.*
  FROM public.procurement_role_roster receiver
  JOIN public.restaurants r ON r.id = receiver.restaurant_id AND r.is_active
  JOIN public.users u ON u.auth_id = receiver.subject_id AND u.is_active
    AND u.role = 'inventory_orderer' AND u.restaurant_id = r.id AND u.primary_store_id = r.id
  JOIN auth.users a ON a.id = u.auth_id
  WHERE receiver.system = 'pos' AND receiver.stage = 'receiver'
    AND receiver.account_kind = 'shared_role' AND receiver.person_id IS NULL
    AND receiver.valid_from <= now() AND receiver.valid_until > now()
    AND EXISTS (SELECT 1 FROM public.store_fixed_account_requirements q
      WHERE q.store_id = r.id AND q.is_active AND q.role = 'inventory_orderer'
        AND q.provisioned_user_id = u.id)
    AND EXISTS (
      SELECT 1 FROM public.restaurants reference
      JOIN public.brands b ON b.id = reference.brand_id
      JOIN public.procurement_role_roster rr ON rr.restaurant_id = reference.id
      JOIN public.procurement_role_roster rv ON rv.restaurant_id = rr.restaurant_id
        AND rv.system = rr.system AND rv.subject_id = rr.subject_id
      WHERE b.code = 'bunsikclub' AND reference.short_code = 'BT' AND reference.is_active
        AND rr.system = 'pos' AND rr.stage = 'receiver' AND rv.stage = 'verifier'
        AND rr.account_kind = 'shared_role' AND rv.account_kind = 'shared_role'
        AND rr.valid_from <= now() AND rr.valid_until > now()
        AND rv.valid_from <= now() AND rv.valid_until > now()
    )
), assigned AS (
  INSERT INTO public.procurement_role_roster (
    restaurant_id, system, subject_id, person_id, account_kind, stage,
    display_name, valid_from, valid_until, reason, assigned_by
  )
  SELECT restaurant_id, system, subject_id, NULL, 'shared_role', 'verifier',
    display_name, now(), valid_until, 'Owner-requested BunsikClub receiving parity',
    '{"system":"migration","subject_id":"20261019081922"}'::jsonb
  FROM eligible
  ON CONFLICT (restaurant_id, system, subject_id, stage) DO NOTHING
  RETURNING *
)
INSERT INTO public.procurement_events (
  restaurant_id, record_id, action, actor, reason, previous_state, next_state
)
SELECT restaurant_id, restaurant_id, 'align_procurement_receiver', assigned_by,
  reason, NULL, to_jsonb(assigned) FROM assigned;

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
  IF EXISTS (
    SELECT 1 FROM public.procurement_events e
    LEFT JOIN public.procurement_role_roster r ON r.restaurant_id=e.restaurant_id
      AND r.system='pos' AND r.stage='verifier' AND r.subject_id=(e.next_state->>'subject_id')::uuid
    WHERE e.action='align_procurement_receiver' AND e.actor->>'subject_id'='20261019081922'
      AND to_jsonb(r) IS DISTINCT FROM e.next_state
  ) THEN RAISE EXCEPTION 'PROCUREMENT_RECEIVER_PARITY_VERIFICATION_FAILED'; END IF;
END $$;
COMMIT;
