-- Cashier-first non-revenue checkout for QR-originated orders.
-- The classification and SERVICE payment are committed atomically so a failed
-- payment cannot leave a customer order partially converted.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS non_revenue_type text,
  ADD COLUMN IF NOT EXISTS non_revenue_reason text,
  ADD COLUMN IF NOT EXISTS non_revenue_staff_name text,
  ADD COLUMN IF NOT EXISTS non_revenue_classified_by uuid,
  ADD COLUMN IF NOT EXISTS non_revenue_classified_at timestamptz;

ALTER TABLE public.orders
  DROP CONSTRAINT IF EXISTS orders_non_revenue_type_check;

ALTER TABLE public.orders
  ADD CONSTRAINT orders_non_revenue_type_check
  CHECK (
    non_revenue_type IS NULL OR
    non_revenue_type IN (
      'staff_meal',
      'influencer_invite',
      'customer_recovery',
      'tasting',
      'other'
    )
  );

COMMENT ON COLUMN public.orders.non_revenue_type IS
  'Required classification for whole-order non-revenue checkout.';
COMMENT ON COLUMN public.orders.non_revenue_reason IS
  'Required operational reason for whole-order non-revenue checkout.';
COMMENT ON COLUMN public.orders.non_revenue_staff_name IS
  'Required staff attribution when non_revenue_type is staff_meal.';

UPDATE public.orders
SET non_revenue_type = 'staff_meal',
    non_revenue_reason = COALESCE(
      NULLIF(btrim(COALESCE(notes, '')), ''),
      'Legacy staff meal'
    ),
    non_revenue_staff_name = COALESCE(
      NULLIF(btrim(COALESCE(non_revenue_staff_name, '')), ''),
      'Legacy staff'
    )
WHERE order_purpose = 'staff_meal'
  AND non_revenue_type IS NULL;

CREATE OR REPLACE FUNCTION public.normalize_staff_meal_classification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_actor_name text;
BEGIN
  IF NEW.order_purpose = 'staff_meal' THEN
    SELECT u.full_name
    INTO v_actor_name
    FROM public.users u
    WHERE u.auth_id = NEW.created_by
    LIMIT 1;

    NEW.non_revenue_type := COALESCE(NEW.non_revenue_type, 'staff_meal');
    NEW.non_revenue_reason := COALESCE(
      NULLIF(btrim(COALESCE(NEW.non_revenue_reason, '')), ''),
      NULLIF(btrim(COALESCE(NEW.notes, '')), '')
    );
    NEW.non_revenue_staff_name := COALESCE(
      NULLIF(btrim(COALESCE(NEW.non_revenue_staff_name, '')), ''),
      NULLIF(btrim(COALESCE(v_actor_name, '')), '')
    );
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS orders_normalize_staff_meal_classification
ON public.orders;
CREATE TRIGGER orders_normalize_staff_meal_classification
BEFORE INSERT OR UPDATE OF order_purpose, notes, non_revenue_type,
  non_revenue_reason, non_revenue_staff_name
ON public.orders
FOR EACH ROW
EXECUTE FUNCTION public.normalize_staff_meal_classification();

REVOKE ALL ON FUNCTION public.normalize_staff_meal_classification()
FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.require_non_revenue_payment_classification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_type text;
  v_reason text;
  v_staff_name text;
BEGIN
  IF NEW.is_revenue IS DISTINCT FROM false THEN
    RETURN NEW;
  END IF;

  SELECT o.non_revenue_type, o.non_revenue_reason, o.non_revenue_staff_name
  INTO v_type, v_reason, v_staff_name
  FROM public.orders o
  WHERE o.id = NEW.order_id
    AND o.restaurant_id = NEW.restaurant_id;

  IF NULLIF(btrim(COALESCE(v_type, '')), '') IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_TYPE_REQUIRED';
  END IF;
  IF NULLIF(btrim(COALESCE(v_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_REASON_REQUIRED';
  END IF;
  IF v_type = 'staff_meal'
     AND NULLIF(btrim(COALESCE(v_staff_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'NON_REVENUE_STAFF_REQUIRED';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS payments_require_non_revenue_classification
ON public.payments;
CREATE TRIGGER payments_require_non_revenue_classification
BEFORE INSERT ON public.payments
FOR EACH ROW
EXECUTE FUNCTION public.require_non_revenue_payment_classification();

REVOKE ALL ON FUNCTION public.require_non_revenue_payment_classification()
FROM PUBLIC, anon, authenticated;

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
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_payment public.payments%ROWTYPE;
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
  IF EXISTS (
    SELECT 1 FROM public.payments WHERE order_id = p_order_id
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
      END
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

CREATE OR REPLACE FUNCTION public.require_discount_reason()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NULLIF(btrim(COALESCE(NEW.reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'DISCOUNT_REASON_REQUIRED';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS order_discounts_require_reason
ON public.order_discounts;
CREATE TRIGGER order_discounts_require_reason
BEFORE INSERT ON public.order_discounts
FOR EACH ROW
EXECUTE FUNCTION public.require_discount_reason();

REVOKE ALL ON FUNCTION public.require_discount_reason()
FROM PUBLIC, anon, authenticated;
