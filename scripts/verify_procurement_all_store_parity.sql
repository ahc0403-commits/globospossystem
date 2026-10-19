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
  IF EXISTS (
    SELECT 1 FROM public.procurement_role_roster receiver
    JOIN public.restaurants r ON r.id=receiver.restaurant_id AND r.is_active
    JOIN public.users u ON u.auth_id=receiver.subject_id AND u.is_active AND u.role='inventory_orderer'
      AND u.restaurant_id=r.id AND u.primary_store_id=r.id
    JOIN auth.users a ON a.id=u.auth_id
    WHERE receiver.system='pos' AND receiver.stage='receiver' AND receiver.account_kind='shared_role'
      AND receiver.valid_from<=now() AND receiver.valid_until>now()
      AND EXISTS(SELECT 1 FROM public.store_fixed_account_requirements q WHERE q.store_id=r.id
        AND q.is_active AND q.role='inventory_orderer' AND q.provisioned_user_id=u.id)
      AND NOT EXISTS(SELECT 1 FROM public.procurement_role_roster verifier
        WHERE verifier.restaurant_id=r.id AND verifier.system='pos' AND verifier.subject_id=u.auth_id
          AND verifier.stage='verifier' AND verifier.account_kind='shared_role'
          AND verifier.valid_from<=now() AND verifier.valid_until>now())
  ) THEN RAISE EXCEPTION 'PROCUREMENT_RECEIVER_PARITY_VERIFICATION_FAILED'; END IF;
  RAISE NOTICE 'PASS: all active ordering-account stores match BunsikClub policy';
END $$;
