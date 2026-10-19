DO $$
DECLARE reference_policy jsonb;
BEGIN
  SELECT to_jsonb(p) - ARRAY['restaurant_id', 'row_version', 'updated_at']
    INTO STRICT reference_policy
  FROM public.procurement_store_policies p
  JOIN public.restaurants r ON r.id = p.restaurant_id
  JOIN public.brands b ON b.id = r.brand_id
  WHERE b.code = 'bunsikclub' AND r.short_code = 'BT' AND r.is_active;
  IF reference_policy->>'enabled' IS DISTINCT FROM 'true'
     OR reference_policy->>'new_requests_enabled' IS DISTINCT FROM 'true'
     OR reference_policy->>'two_stage_required' IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'PROCUREMENT_PARITY_REFERENCE_NOT_READY';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.restaurants r
    LEFT JOIN public.procurement_store_policies p ON p.restaurant_id = r.id
    WHERE r.is_active AND EXISTS (
      SELECT 1 FROM public.store_fixed_account_requirements q
      WHERE q.store_id = r.id AND q.is_active AND q.role = 'inventory_orderer'
    ) AND (to_jsonb(p) - ARRAY['restaurant_id', 'row_version', 'updated_at'])
      IS DISTINCT FROM reference_policy
  ) THEN
    RAISE EXCEPTION 'PROCUREMENT_PARITY_VERIFICATION_FAILED';
  END IF;
  RAISE NOTICE 'PASS: all active ordering-account stores match BunsikClub policy';
END $$;
