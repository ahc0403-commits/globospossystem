BEGIN;

SET LOCAL lock_timeout = '5s';

CREATE TABLE public.non_revenue_checkout_20260923010000_backup (
  object_identity text PRIMARY KEY,
  definition text NOT NULL,
  captured_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.non_revenue_checkout_20260923010000_backup
  ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.non_revenue_checkout_20260923010000_backup
FROM PUBLIC, anon, authenticated, service_role;

INSERT INTO public.non_revenue_checkout_20260923010000_backup (
  object_identity,
  definition
)
SELECT procedure_name, pg_get_functiondef(procedure_name::regprocedure)
FROM unnest(ARRAY[
  'public.process_payment(uuid,uuid,numeric,text)',
  'public.process_non_revenue_payment(uuid,uuid,numeric,text,text,text,text)',
  'public.add_items_to_order(uuid,uuid,jsonb)',
  'public.qr_place_order(text,jsonb,uuid,boolean,uuid)'
]) procedure_name;

-- A SERVICE payment closes the whole order. If the order total changed while
-- the cashier was entering the non-revenue details, roll the attempt back and
-- require the cashier to review the new amount.
CREATE OR REPLACE FUNCTION public.process_payment(
  p_order_id uuid,
  p_store_id uuid,
  p_amount numeric,
  p_method text
) RETURNS public.payments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_before jsonb;
  v_payment public.payments%ROWTYPE;
  v_order_status text;
BEGIN
  IF NOT EXISTS (
       SELECT 1
       FROM public.users
       WHERE auth_id = auth.uid()
         AND is_active = true
         AND role IN (
           'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
         )
     )
     OR p_store_id IS NULL
     OR (
       NOT COALESCE(public.is_super_admin(), false)
       AND NOT EXISTS (
         SELECT 1
         FROM public.user_accessible_stores(auth.uid()) s(id)
         WHERE s.id = p_store_id
       )
     ) THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  PERFORM id
  FROM public.order_discounts
  WHERE order_id = p_order_id
    AND restaurant_id = p_store_id
    AND status = 'active'
  FOR UPDATE;

  v_before := public.order_promotion_fingerprint(p_order_id, p_store_id);
  PERFORM public.sync_active_order_promotion(p_order_id, p_store_id, now());

  IF v_before IS DISTINCT FROM
     public.order_promotion_fingerprint(p_order_id, p_store_id) THEN
    RAISE EXCEPTION 'PAYMENT_AMOUNT_MISMATCH'
      USING DETAIL = 'PROMOTION_PRICE_CHANGED';
  END IF;

  v_payment := public.process_payment_before_promotion_read_split(
    p_order_id,
    p_store_id,
    p_amount,
    p_method
  );

  IF p_method = 'SERVICE' THEN
    SELECT status
    INTO v_order_status
    FROM public.orders
    WHERE id = p_order_id
      AND restaurant_id = p_store_id;

    IF v_order_status IS DISTINCT FROM 'completed' THEN
      RAISE EXCEPTION 'PAYMENT_AMOUNT_MISMATCH'
        USING DETAIL = 'SERVICE_TOTAL_CHANGED';
    END IF;
  END IF;

  RETURN v_payment;
END;
$$;

REVOKE ALL ON FUNCTION public.process_payment(uuid, uuid, numeric, text)
FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.process_payment(uuid, uuid, numeric, text)
TO authenticated, service_role;

-- Permit a previously classified non-revenue order to finish only when every
-- existing payment is also non-revenue and the classification is unchanged.
-- This repairs historical partial SERVICE payments without opening a path to
-- convert a revenue payment into a non-revenue checkout.
CREATE OR REPLACE FUNCTION public.process_non_revenue_payment(
  p_order_id uuid,
  p_store_id uuid,
  p_amount numeric,
  p_type text,
  p_reason text,
  p_staff_name text DEFAULT NULL,
  p_manager_pin text DEFAULT NULL
) RETURNS public.payments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_payment public.payments%ROWTYPE;
  v_resuming boolean := false;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = true
  LIMIT 1;

  IF NOT FOUND
     OR v_actor.role NOT IN (
       'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
     ) THEN
    RAISE EXCEPTION 'NON_REVENUE_FORBIDDEN';
  END IF;

  IF p_type NOT IN (
    'staff_meal',
    'influencer_invite',
    'customer_recovery',
    'tasting',
    'other'
  ) THEN
    RAISE EXCEPTION 'NON_REVENUE_TYPE_INVALID';
  END IF;

  IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_REASON_REQUIRED';
  END IF;

  IF p_type = 'staff_meal'
     AND NULLIF(btrim(COALESCE(p_staff_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_STAFF_REQUIRED';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'NON_REVENUE_FORBIDDEN';
  END IF;

  PERFORM public.verify_discount_manager_pin_or_raise(
    p_store_id,
    p_manager_pin,
    'process_non_revenue_payment'
  );

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
    RAISE EXCEPTION 'NON_REVENUE_ORDER_NOT_PAYABLE';
  END IF;

  v_resuming := EXISTS (
    SELECT 1 FROM public.payments WHERE order_id = p_order_id
  );

  IF v_resuming AND (
       v_order.non_revenue_type IS DISTINCT FROM p_type
       OR EXISTS (
         SELECT 1
         FROM public.payments
         WHERE order_id = p_order_id
           AND is_revenue IS DISTINCT FROM false
       )
     ) THEN
    RAISE EXCEPTION 'NON_REVENUE_AFTER_PAYMENT';
  END IF;

  UPDATE public.orders
  SET order_purpose = CASE
        WHEN p_type = 'staff_meal' THEN 'staff_meal'
        ELSE 'customer'
      END,
      non_revenue_type = p_type,
      non_revenue_reason = btrim(p_reason),
      non_revenue_staff_name = CASE
        WHEN p_type = 'staff_meal' THEN btrim(p_staff_name)
        ELSE NULL
      END,
      non_revenue_classified_by = auth.uid(),
      non_revenue_classified_at = now(),
      updated_at = now()
  WHERE id = p_order_id;

  v_payment := public.process_payment(
    p_order_id,
    p_store_id,
    p_amount,
    'SERVICE'
  );

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  ) VALUES (
    auth.uid(),
    'process_non_revenue_payment',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'payment_id', v_payment.id,
      'non_revenue_type', p_type,
      'reason', btrim(p_reason),
      'staff_name', CASE
        WHEN p_type = 'staff_meal' THEN btrim(p_staff_name)
        ELSE NULL
      END,
      'resumed_partial_non_revenue', v_resuming
    )
  );

  RETURN v_payment;
END;
$$;

REVOKE ALL ON FUNCTION public.process_non_revenue_payment(
  uuid, uuid, numeric, text, text, text, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_non_revenue_payment(
  uuid, uuid, numeric, text, text, text, text
) TO authenticated, service_role;

-- Staff-entered additions serialize on the order row. Once a non-revenue
-- payment exists, no new item may be appended to that same order.
ALTER FUNCTION public.add_items_to_order(uuid, uuid, jsonb)
  RENAME TO add_items_to_order_before_non_revenue_guard;

REVOKE ALL ON FUNCTION public.add_items_to_order_before_non_revenue_guard(
  uuid, uuid, jsonb
) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.add_items_to_order(
  p_order_id uuid,
  p_store_id uuid,
  p_items jsonb
) RETURNS SETOF public.order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
BEGIN
  IF NOT EXISTS (
       SELECT 1
       FROM public.users
       WHERE auth_id = auth.uid()
         AND is_active = true
         AND role IN ('waiter', 'admin', 'store_admin', 'super_admin')
     )
     OR (
       NOT COALESCE(public.is_super_admin(), false)
       AND NOT EXISTS (
         SELECT 1
         FROM public.user_accessible_stores(auth.uid()) s(store_id)
         WHERE s.store_id = p_store_id
       )
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  PERFORM 1
  FROM public.orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF EXISTS (
    SELECT 1
    FROM public.payments
    WHERE order_id = p_order_id
      AND is_revenue IS DISTINCT FROM true
  ) THEN
    RAISE EXCEPTION 'ORDER_NON_REVENUE_PAYMENT_STARTED';
  END IF;

  RETURN QUERY
  SELECT *
  FROM public.add_items_to_order_before_non_revenue_guard(
    p_order_id,
    p_store_id,
    p_items
  );
END;
$$;

REVOKE ALL ON FUNCTION public.add_items_to_order(uuid, uuid, jsonb)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_items_to_order(uuid, uuid, jsonb)
TO authenticated, service_role;

-- QR additions use the same order-row lock as payment. Idempotent retries are
-- returned before the guard so a successfully accepted batch stays retry-safe.
ALTER FUNCTION public.qr_place_order(text, jsonb, uuid, boolean, uuid)
  RENAME TO qr_place_order_before_non_revenue_guard;

REVOKE ALL ON FUNCTION public.qr_place_order_before_non_revenue_guard(
  text, jsonb, uuid, boolean, uuid
) FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.qr_place_order(
  p_token text,
  p_items jsonb,
  p_client_order_id uuid,
  p_validate_combo_choices boolean,
  p_expected_order_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, pg_catalog
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_existing public.qr_order_batches%ROWTYPE;
  v_current_order_id uuid;
BEGIN
  SELECT qr.restaurant_id, qr.table_id
  INTO v_table
  FROM public.table_qr_tokens qr
  JOIN public.tables table_row
    ON table_row.id = qr.table_id
   AND table_row.restaurant_id = qr.restaurant_id
  JOIN public.restaurants restaurant
    ON restaurant.id = qr.restaurant_id
   AND restaurant.is_active = true
  WHERE qr.token = v_token
    AND qr.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QR_TOKEN_INVALID';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.qr_order_batches batch
  WHERE batch.client_order_id = p_client_order_id
    AND batch.restaurant_id = v_table.restaurant_id
    AND batch.table_id = v_table.table_id;

  IF FOUND THEN
    RETURN v_existing.result_snapshot;
  END IF;

  SELECT order_row.id
  INTO v_current_order_id
  FROM public.orders order_row
  WHERE order_row.table_id = v_table.table_id
    AND order_row.restaurant_id = v_table.restaurant_id
    AND order_row.status IN ('pending', 'confirmed', 'serving')
  ORDER BY order_row.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF v_current_order_id IS NOT NULL
     AND EXISTS (
       SELECT 1
       FROM public.payments payment
       WHERE payment.order_id = v_current_order_id
         AND payment.is_revenue IS DISTINCT FROM true
     ) THEN
    RAISE EXCEPTION 'QR_ORDER_PAYMENT_IN_PROGRESS';
  END IF;

  RETURN public.qr_place_order_before_non_revenue_guard(
    p_token,
    p_items,
    p_client_order_id,
    p_validate_combo_choices,
    p_expected_order_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.qr_place_order(
  text, jsonb, uuid, boolean, uuid
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.qr_place_order(
  text, jsonb, uuid, boolean, uuid
) TO anon, authenticated, service_role;

COMMIT;
