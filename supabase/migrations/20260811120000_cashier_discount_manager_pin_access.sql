BEGIN;

-- production-gate: self-verifying

-- Cashiers operate the checkout surface and may submit discounts, but every
-- discount remains store-scoped and requires the configured manager PIN.
CREATE OR REPLACE FUNCTION public.apply_order_discount(
  p_order_id uuid,
  p_store_id uuid,
  p_type text,
  p_mode text,
  p_value numeric,
  p_reason text DEFAULT NULL,
  p_coupon_code text DEFAULT NULL,
  p_proof_storage_path text DEFAULT NULL,
  p_manager_pin text DEFAULT NULL
) RETURNS public.order_discounts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_discount public.order_discounts%ROWTYPE;
  v_discountable_total numeric(15,2);
  v_discount_amount numeric(15,2);
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND
     OR v_actor.role NOT IN (
       'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
     ) THEN
    RAISE EXCEPTION 'DISCOUNT_FORBIDDEN';
  END IF;

  IF p_order_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'DISCOUNT_ORDER_REQUIRED';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'DISCOUNT_FORBIDDEN';
  END IF;

  PERFORM public.verify_discount_manager_pin_or_raise(
    p_store_id,
    p_manager_pin,
    'apply_order_discount'
  );

  IF p_type NOT IN ('promotion', 'coupon', 'manual') THEN
    RAISE EXCEPTION 'DISCOUNT_TYPE_INVALID';
  END IF;

  IF p_mode NOT IN ('amount', 'percent') THEN
    RAISE EXCEPTION 'DISCOUNT_MODE_INVALID';
  END IF;

  IF p_value IS NULL OR p_value <= 0 THEN
    RAISE EXCEPTION 'DISCOUNT_VALUE_INVALID';
  END IF;

  IF p_mode = 'percent' AND p_value > 100 THEN
    RAISE EXCEPTION 'DISCOUNT_PERCENT_INVALID';
  END IF;

  IF NULLIF(btrim(COALESCE(p_proof_storage_path, '')), '') IS NULL THEN
    RAISE EXCEPTION 'DISCOUNT_PROOF_REQUIRED';
  END IF;

  IF split_part(p_proof_storage_path, '/', 2) <> p_store_id::text THEN
    RAISE EXCEPTION 'DISCOUNT_PROOF_SCOPE_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM storage.objects obj
    WHERE obj.bucket_id = 'discount-proofs'
      AND obj.name = btrim(p_proof_storage_path)
  ) THEN
    RAISE EXCEPTION 'DISCOUNT_PROOF_NOT_FOUND';
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status <> 'serving' THEN
    RAISE EXCEPTION 'DISCOUNT_ORDER_NOT_PAYABLE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_discounts
    WHERE order_id = p_order_id
      AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'DISCOUNT_ALREADY_ACTIVE';
  END IF;

  v_discountable_total := public.calculate_order_discountable_total(
    p_order_id,
    p_store_id
  );

  IF v_discountable_total <= 0 THEN
    RAISE EXCEPTION 'DISCOUNT_TOTAL_INVALID';
  END IF;

  IF p_mode = 'percent' THEN
    v_discount_amount := ROUND(v_discountable_total * p_value / 100, 2);
  ELSE
    v_discount_amount := LEAST(ROUND(p_value, 2), v_discountable_total);
  END IF;

  IF v_discount_amount <= 0 THEN
    RAISE EXCEPTION 'DISCOUNT_AMOUNT_INVALID';
  END IF;

  INSERT INTO public.order_discounts (
    restaurant_id,
    order_id,
    discount_type,
    discount_mode,
    discount_value,
    discount_amount,
    reason,
    coupon_code,
    proof_storage_path,
    applied_by,
    approved_via,
    status
  )
  VALUES (
    p_store_id,
    p_order_id,
    p_type,
    p_mode,
    ROUND(p_value, 2),
    v_discount_amount,
    NULLIF(btrim(COALESCE(p_reason, '')), ''),
    NULLIF(btrim(COALESCE(p_coupon_code, '')), ''),
    btrim(p_proof_storage_path),
    auth.uid(),
    'manager_pin',
    'active'
  )
  RETURNING * INTO v_discount;

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  )
  VALUES (
    auth.uid(),
    'apply_order_discount',
    'order_discounts',
    v_discount.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', p_order_id,
      'discount_type', p_type,
      'discount_mode', p_mode,
      'discount_value', p_value,
      'discount_amount', v_discount_amount,
      'proof_storage_path', p_proof_storage_path
    )
  );

  RETURN v_discount;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_order_discount(
  uuid, uuid, text, text, numeric, text, text, text, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.apply_order_discount(
  uuid, uuid, text, text, numeric, text, text, text, text
) TO authenticated, service_role;

DO $verify$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.apply_order_discount(uuid,uuid,text,text,numeric,text,text,text,text)'::regprocedure
  ) INTO v_definition;

  IF position('''cashier''' IN v_definition) = 0
     OR position('verify_discount_manager_pin_or_raise' IN v_definition) = 0
     OR position('user_accessible_stores' IN v_definition) = 0
     OR NOT has_function_privilege(
       'authenticated',
       'public.apply_order_discount(uuid,uuid,text,text,numeric,text,text,text,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'CASHIER_DISCOUNT_MANAGER_PIN_ACCESS_VERIFICATION_FAILED';
  END IF;
END;
$verify$;

COMMIT;
