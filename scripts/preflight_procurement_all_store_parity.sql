-- Read-only: show every operational ordering ID and policy differences.
DO $$
BEGIN
  IF (SELECT count(*) FROM public.procurement_store_policies p
      JOIN public.restaurants r ON r.id = p.restaurant_id
      JOIN public.brands b ON b.id = r.brand_id
      WHERE b.code = 'bunsikclub' AND r.short_code = 'BT' AND r.is_active
        AND p.enabled AND p.new_requests_enabled AND p.two_stage_required) <> 1 THEN
    RAISE EXCEPTION 'PROCUREMENT_PARITY_REFERENCE_NOT_READY';
  END IF;
END $$;

WITH reference AS (
  SELECT to_jsonb(p) - ARRAY['restaurant_id', 'row_version', 'updated_at'] AS policy
  FROM public.procurement_store_policies p
  JOIN public.restaurants r ON r.id = p.restaurant_id
  JOIN public.brands b ON b.id = r.brand_id
  WHERE b.code = 'bunsikclub' AND r.short_code = 'BT' AND r.is_active
)
SELECT r.name AS store_name, q.account_code,
  (to_jsonb(p) - ARRAY['restaurant_id', 'row_version', 'updated_at'])
    IS DISTINCT FROM reference.policy AS requires_policy_alignment
FROM public.store_fixed_account_requirements q
JOIN public.restaurants r ON r.id = q.store_id
LEFT JOIN public.procurement_store_policies p ON p.restaurant_id = r.id
CROSS JOIN reference
WHERE r.is_active AND q.is_active AND q.role = 'inventory_orderer'
ORDER BY r.name, q.account_code;
