BEGIN;

-- Discount + staff-meal V1 schema/RPC foundation.
-- DB-first and additive for old clients: no existing caller sends discounts
-- or staff-meal purpose until the Flutter rollout.

ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS order_purpose text NOT NULL DEFAULT 'customer';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'orders_order_purpose_check'
      AND conrelid = 'public.orders'::regclass
  ) THEN
    ALTER TABLE public.orders
      ADD CONSTRAINT orders_order_purpose_check
      CHECK (order_purpose IN ('customer', 'staff_meal'));
  END IF;
END;
$$;

COMMENT ON COLUMN public.orders.order_purpose IS
  'customer = regular guest order; staff_meal = staff meal closed through SERVICE/non-revenue payment.';

CREATE TABLE IF NOT EXISTS public.order_discounts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  order_id uuid NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  discount_type text NOT NULL CHECK (discount_type IN ('promotion', 'coupon', 'manual')),
  discount_mode text NOT NULL CHECK (discount_mode IN ('amount', 'percent')),
  discount_value numeric(12,2) NOT NULL CHECK (discount_value > 0),
  discount_amount numeric(12,2) NOT NULL CHECK (discount_amount >= 0),
  reason text,
  coupon_code text,
  proof_storage_path text NOT NULL,
  applied_by uuid NOT NULL REFERENCES auth.users(id),
  approved_via text NOT NULL DEFAULT 'manager_pin',
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'voided', 'consumed')),
  void_reason text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.order_discounts IS
  'Audited order-level discounts. Writes are RPC-only; one active discount per order.';
COMMENT ON COLUMN public.order_discounts.proof_storage_path IS
  'Supabase Storage object path in discount-proofs. Proof is mandatory before apply.';

CREATE UNIQUE INDEX IF NOT EXISTS order_discounts_one_active
  ON public.order_discounts(order_id)
  WHERE status = 'active';

CREATE INDEX IF NOT EXISTS order_discounts_store_day
  ON public.order_discounts(restaurant_id, created_at);

ALTER TABLE public.order_discounts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS order_discounts_store_read ON public.order_discounts;
CREATE POLICY order_discounts_store_read
ON public.order_discounts
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) s(store_id)
    WHERE s.store_id = order_discounts.restaurant_id
  )
  OR public.is_super_admin()
);

REVOKE ALL ON public.order_discounts FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.order_discounts TO authenticated;
GRANT ALL ON public.order_discounts TO service_role;

CREATE OR REPLACE FUNCTION public.calculate_order_discountable_total(
  p_order_id uuid,
  p_store_id uuid
) RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_vat_pricing_mode text := 'exclusive';
  v_item record;
  v_vat_rate numeric(5,2);
  v_line_gross numeric(15,2);
  v_line_inc numeric(15,2);
  v_total numeric(15,2) := 0;
BEGIN
  IF p_order_id IS NULL OR p_store_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT COALESCE(r.vat_pricing_mode, 'exclusive')
  INTO v_vat_pricing_mode
  FROM public.restaurants r
  WHERE r.id = p_store_id;

  FOR v_item IN
    SELECT
      oi.unit_price,
      oi.quantity,
      COALESCE(mi.vat_category, 'food') AS vat_category
    FROM public.order_items oi
    LEFT JOIN public.menu_items mi ON mi.id = oi.menu_item_id
    WHERE oi.order_id = p_order_id
      AND oi.restaurant_id = p_store_id
      AND oi.status <> 'cancelled'
      AND oi.item_type = 'menu_item'
  LOOP
    v_line_gross := ROUND(v_item.unit_price * v_item.quantity, 2);
    v_vat_rate := CASE v_item.vat_category WHEN 'alcohol' THEN 10 ELSE 8 END;
    IF v_vat_pricing_mode = 'inclusive' THEN
      v_line_inc := v_line_gross;
    ELSE
      v_line_inc := v_line_gross + ROUND(v_line_gross * v_vat_rate / 100, 2);
    END IF;
    v_total := v_total + v_line_inc;
  END LOOP;

  RETURN ROUND(v_total, 2);
END;
$$;

REVOKE ALL ON FUNCTION public.calculate_order_discountable_total(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_order_discountable_total(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.set_discount_manager_pin(
  p_store_id uuid,
  p_pin text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_updated public.restaurant_settings%ROWTYPE;
  v_hash text;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;

  IF p_pin IS NULL OR p_pin !~ '^[0-9]{4,8}$' THEN
    RAISE EXCEPTION 'DISCOUNT_PIN_INVALID';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  v_hash := extensions.crypt(p_pin, extensions.gen_salt('bf'));

  INSERT INTO public.restaurant_settings (restaurant_id, settings_json, updated_at)
  VALUES (
    p_store_id,
    jsonb_build_object('discount_manager_pin_hash', v_hash),
    now()
  )
  ON CONFLICT (restaurant_id)
  DO UPDATE SET
    settings_json = jsonb_set(
      COALESCE(public.restaurant_settings.settings_json, '{}'::jsonb),
      '{discount_manager_pin_hash}',
      to_jsonb(v_hash),
      true
    ),
    updated_at = now()
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'set_discount_manager_pin',
    'restaurant_settings',
    v_updated.id,
    jsonb_build_object('store_id', p_store_id, 'updated_at_utc', now())
  );

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.clear_discount_manager_pin(
  p_store_id uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_updated public.restaurant_settings%ROWTYPE;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  INSERT INTO public.restaurant_settings (restaurant_id, settings_json, updated_at)
  VALUES (
    p_store_id,
    jsonb_build_object('discount_manager_pin_hash', NULL),
    now()
  )
  ON CONFLICT (restaurant_id)
  DO UPDATE SET
    settings_json = COALESCE(public.restaurant_settings.settings_json, '{}'::jsonb) - 'discount_manager_pin_hash',
    updated_at = now()
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'clear_discount_manager_pin',
    'restaurant_settings',
    v_updated.id,
    jsonb_build_object('store_id', p_store_id, 'updated_at_utc', now())
  );

  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.has_discount_manager_pin(
  p_store_id uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_has_pin boolean;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  SELECT NULLIF(settings_json->>'discount_manager_pin_hash', '') IS NOT NULL
  INTO v_has_pin
  FROM public.restaurant_settings
  WHERE restaurant_id = p_store_id;

  RETURN COALESCE(v_has_pin, false);
END;
$$;

CREATE OR REPLACE FUNCTION public.verify_discount_manager_pin_or_raise(
  p_store_id uuid,
  p_pin text,
  p_action text
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_pin_hash text;
BEGIN
  SELECT settings_json->>'discount_manager_pin_hash'
  INTO v_pin_hash
  FROM public.restaurant_settings
  WHERE restaurant_id = p_store_id;

  IF NULLIF(v_pin_hash, '') IS NULL THEN
    RAISE EXCEPTION 'DISCOUNT_PIN_NOT_CONFIGURED';
  END IF;

  IF NULLIF(btrim(COALESCE(p_pin, '')), '') IS NULL
     OR extensions.crypt(p_pin, v_pin_hash) <> v_pin_hash THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'discount_pin_rejected',
      'restaurants',
      p_store_id,
      jsonb_build_object('store_id', p_store_id, 'requested_action', p_action, 'created_at_utc', now())
    );

    RAISE EXCEPTION 'DISCOUNT_PIN_REJECTED';
  END IF;
END;
$$;

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
     OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin')
     OR NOT (
       v_actor.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
       OR COALESCE(v_actor.extra_permissions, ARRAY[]::text[]) @> ARRAY['discount_apply']
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

  PERFORM public.verify_discount_manager_pin_or_raise(p_store_id, p_manager_pin, 'apply_order_discount');

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

  v_discountable_total := public.calculate_order_discountable_total(p_order_id, p_store_id);

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

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
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

CREATE OR REPLACE FUNCTION public.void_order_discount(
  p_discount_id uuid,
  p_store_id uuid,
  p_reason text DEFAULT NULL
) RETURNS public.order_discounts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_discount public.order_discounts%ROWTYPE;
  v_order_status text;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND
     OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin')
     OR NOT (
       v_actor.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
       OR COALESCE(v_actor.extra_permissions, ARRAY[]::text[]) @> ARRAY['discount_apply']
     ) THEN
    RAISE EXCEPTION 'DISCOUNT_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'DISCOUNT_FORBIDDEN';
  END IF;

  SELECT d.*
  INTO v_discount
  FROM public.order_discounts d
  WHERE d.id = p_discount_id
    AND d.restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'DISCOUNT_NOT_FOUND';
  END IF;

  IF v_discount.status <> 'active' THEN
    RAISE EXCEPTION 'DISCOUNT_NOT_ACTIVE';
  END IF;

  SELECT status
  INTO v_order_status
  FROM public.orders
  WHERE id = v_discount.order_id
  FOR UPDATE;

  IF v_order_status = 'completed' THEN
    RAISE EXCEPTION 'DISCOUNT_ORDER_COMPLETED';
  END IF;

  UPDATE public.order_discounts
  SET status = 'voided',
      void_reason = COALESCE(NULLIF(btrim(COALESCE(p_reason, '')), ''), 'manual_void'),
      updated_at = now()
  WHERE id = v_discount.id
  RETURNING * INTO v_discount;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'void_order_discount',
    'order_discounts',
    v_discount.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_discount.order_id,
      'reason', v_discount.void_reason
    )
  );

  RETURN v_discount;
END;
$$;

CREATE OR REPLACE FUNCTION public.void_active_order_discount_for_item_change(
  p_order_id uuid,
  p_store_id uuid,
  p_reason text DEFAULT 'order_items_changed'
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_discount public.order_discounts%ROWTYPE;
  v_count integer := 0;
BEGIN
  SELECT *
  INTO v_discount
  FROM public.order_discounts
  WHERE order_id = p_order_id
    AND restaurant_id = p_store_id
    AND status = 'active'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN 0;
  END IF;

  UPDATE public.order_discounts
  SET status = 'voided',
      void_reason = COALESCE(NULLIF(btrim(COALESCE(p_reason, '')), ''), 'order_items_changed'),
      updated_at = now()
  WHERE id = v_discount.id;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'auto_void_order_discount',
    'order_discounts',
    v_discount.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', p_order_id,
      'reason', COALESCE(NULLIF(btrim(COALESCE(p_reason, '')), ''), 'order_items_changed')
    )
  );

  RETURN v_count;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_staff_meal_order(
  p_store_id uuid,
  p_items jsonb,
  p_staff_user_id uuid DEFAULT NULL,
  p_reason text DEFAULT NULL,
  p_manager_pin text DEFAULT NULL
) RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_staff public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_item_count integer := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'STAFF_MEAL_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STAFF_MEAL_FORBIDDEN';
  END IF;

  PERFORM public.verify_discount_manager_pin_or_raise(p_store_id, p_manager_pin, 'create_staff_meal_order');

  IF p_staff_user_id IS NOT NULL THEN
    SELECT *
    INTO v_staff
    FROM public.users
    WHERE id = p_staff_user_id
      AND restaurant_id = p_store_id
      AND is_active = TRUE
    LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'STAFF_MEAL_USER_NOT_FOUND';
    END IF;
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::int, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN public.menu_items m
      ON m.id = (item->>'menu_item_id')::uuid
     AND m.restaurant_id = p_store_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  INSERT INTO public.orders (
    restaurant_id,
    table_id,
    status,
    order_purpose,
    notes,
    created_by
  )
  VALUES (
    p_store_id,
    NULL,
    'pending',
    'staff_meal',
    NULLIF(btrim(COALESCE(p_reason, '')), ''),
    auth.uid()
  )
  RETURNING * INTO v_order;

  INSERT INTO public.order_items (
    order_id,
    menu_item_id,
    quantity,
    unit_price,
    label,
    display_name,
    restaurant_id,
    item_type
  )
  SELECT
    v_order.id,
    m.id,
    (item->>'quantity')::int,
    m.price,
    m.name,
    m.name,
    p_store_id,
    'menu_item'
  FROM jsonb_array_elements(p_items) item
  JOIN public.menu_items m
    ON m.id = (item->>'menu_item_id')::uuid
   AND m.restaurant_id = p_store_id
   AND m.is_available = TRUE;

  GET DIAGNOSTICS v_item_count = ROW_COUNT;

  IF to_regprocedure('public.enqueue_print_jobs(uuid,text[],jsonb,text)') IS NOT NULL THEN
    PERFORM public.enqueue_print_jobs(
      v_order.id,
      ARRAY['kitchen', 'floor'],
      p_items,
      'initial'
    );
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_staff_meal_order',
    'orders',
    v_order.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'staff_user_id', p_staff_user_id,
      'item_count', v_item_count,
      'reason', NULLIF(btrim(COALESCE(p_reason, '')), '')
    )
  );

  RETURN v_order;
END;
$$;

CREATE OR REPLACE FUNCTION public.cancel_order_item(
  p_item_id uuid,
  p_store_id uuid
) RETURNS public.order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_order_status text;
  v_from_status text;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_item
  FROM public.order_items
  WHERE id = p_item_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  SELECT status
  INTO v_order_status
  FROM public.orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF v_item.status NOT IN ('pending', 'preparing', 'ready') THEN
    RAISE EXCEPTION 'ITEM_NOT_CANCELLABLE';
  END IF;

  v_from_status := v_item.status;

  UPDATE public.order_items
  SET status = 'cancelled'
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  PERFORM public.recalc_order_status(v_item.order_id);
  PERFORM public.void_active_order_discount_for_item_change(v_item.order_id, p_store_id, 'order_items_changed');

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'cancel_order_item',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_item.order_id,
      'from_status', v_from_status,
      'to_status', 'cancelled',
      'label', v_item.label,
      'quantity', v_item.quantity,
      'unit_price', v_item.unit_price
    )
  );

  RETURN v_item;
END;
$$;

CREATE OR REPLACE FUNCTION public.add_items_to_order(
  p_order_id uuid,
  p_store_id uuid,
  p_items jsonb
) RETURNS SETOF public.order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_inserted_count int := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
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

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::int, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN public.menu_items m
      ON m.id = (item->>'menu_item_id')::uuid
     AND m.restaurant_id = p_store_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  RETURN QUERY
  INSERT INTO public.order_items (
    order_id, menu_item_id, quantity, unit_price,
    label, display_name, restaurant_id, item_type
  )
  SELECT
    p_order_id, m.id, (item->>'quantity')::int, m.price,
    m.name, m.name, p_store_id, 'menu_item'
  FROM jsonb_array_elements(p_items) item
  JOIN public.menu_items m
    ON m.id = (item->>'menu_item_id')::uuid
   AND m.restaurant_id = p_store_id
   AND m.is_available = TRUE
  RETURNING *;

  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  PERFORM public.recalc_order_status(p_order_id);
  PERFORM public.void_active_order_discount_for_item_change(p_order_id, p_store_id, 'order_items_changed');

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'add_items_to_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'added_item_count', v_inserted_count
    )
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.edit_order_item_quantity(
  p_item_id uuid,
  p_store_id uuid,
  p_new_quantity integer
) RETURNS public.order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_order_status text;
  v_old_quantity int;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF p_new_quantity IS NULL OR p_new_quantity < 1 THEN
    RAISE EXCEPTION 'INVALID_QUANTITY';
  END IF;

  SELECT *
  INTO v_item
  FROM public.order_items
  WHERE id = p_item_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  SELECT status
  INTO v_order_status
  FROM public.orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF v_item.status <> 'pending' THEN
    RAISE EXCEPTION 'ITEM_NOT_EDITABLE';
  END IF;

  v_old_quantity := v_item.quantity;

  IF v_old_quantity = p_new_quantity THEN
    RETURN v_item;
  END IF;

  UPDATE public.order_items
  SET quantity = p_new_quantity
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  PERFORM public.recalc_order_status(v_item.order_id);
  PERFORM public.void_active_order_discount_for_item_change(v_item.order_id, p_store_id, 'order_items_changed');

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'edit_order_item_quantity',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_item.order_id,
      'label', v_item.label,
      'old_quantity', v_old_quantity,
      'new_quantity', p_new_quantity
    )
  );

  RETURN v_item;
END;
$$;

REVOKE ALL ON FUNCTION public.set_discount_manager_pin(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.clear_discount_manager_pin(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.has_discount_manager_pin(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.verify_discount_manager_pin_or_raise(uuid, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.apply_order_discount(uuid, uuid, text, text, numeric, text, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.void_order_discount(uuid, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.void_active_order_discount_for_item_change(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_staff_meal_order(uuid, jsonb, uuid, text, text) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.set_discount_manager_pin(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.clear_discount_manager_pin(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.has_discount_manager_pin(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.apply_order_discount(uuid, uuid, text, text, numeric, text, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.void_order_discount(uuid, uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_staff_meal_order(uuid, jsonb, uuid, text, text) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_cashier_today_summary(
  p_store_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_today_start timestamptz;
  v_today_end timestamptz;
  v_result jsonb;
  v_payments_count int;
  v_payments_total numeric;
  v_payments_cash numeric;
  v_payments_card numeric;
  v_payments_pay numeric;
  v_service_count int;
  v_service_total numeric;
  v_staff_meal_count int;
  v_staff_meal_total numeric;
  v_discount_total numeric;
  v_orders_completed int;
  v_orders_cancelled int;
  v_orders_active int;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'CASHIER_SUMMARY_STORE_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'CASHIER_SUMMARY_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'CASHIER_SUMMARY_FORBIDDEN';
  END IF;

  v_today_start := (NOW() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_today_end := v_today_start + interval '1 day';

  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(amount), 0),
    COALESCE(SUM(CASE WHEN method = 'CASH' THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN method IN ('CREDITCARD', 'ATM') THEN amount ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN method NOT IN ('CASH', 'CREDITCARD', 'ATM') THEN amount ELSE 0 END), 0)
  INTO v_payments_count, v_payments_total, v_payments_cash, v_payments_card, v_payments_pay
  FROM public.payments
  WHERE restaurant_id = p_store_id
    AND is_revenue = TRUE
    AND created_at >= v_today_start
    AND created_at < v_today_end;

  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(p.amount), 0)
  INTO v_service_count, v_service_total
  FROM public.payments p
  JOIN public.orders o ON o.id = p.order_id
  WHERE p.restaurant_id = p_store_id
    AND p.is_revenue = FALSE
    AND COALESCE(o.order_purpose, 'customer') <> 'staff_meal'
    AND p.created_at >= v_today_start
    AND p.created_at < v_today_end;

  SELECT
    COALESCE(COUNT(*), 0),
    COALESCE(SUM(p.amount), 0)
  INTO v_staff_meal_count, v_staff_meal_total
  FROM public.payments p
  JOIN public.orders o ON o.id = p.order_id
  WHERE p.restaurant_id = p_store_id
    AND p.is_revenue = FALSE
    AND COALESCE(o.order_purpose, 'customer') = 'staff_meal'
    AND p.created_at >= v_today_start
    AND p.created_at < v_today_end;

  SELECT COALESCE(SUM(discount_amount), 0)
  INTO v_discount_total
  FROM public.order_discounts
  WHERE restaurant_id = p_store_id
    AND status = 'consumed'
    AND updated_at >= v_today_start
    AND updated_at < v_today_end;

  SELECT
    COALESCE(SUM(CASE WHEN status = 'completed' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END), 0),
    COALESCE(SUM(CASE WHEN status NOT IN ('completed', 'cancelled') THEN 1 ELSE 0 END), 0)
  INTO v_orders_completed, v_orders_cancelled, v_orders_active
  FROM public.orders
  WHERE restaurant_id = p_store_id
    AND created_at >= v_today_start
    AND created_at < v_today_end;

  v_result := jsonb_build_object(
    'payments_count', v_payments_count,
    'payments_total', v_payments_total,
    'payments_cash', v_payments_cash,
    'payments_card', v_payments_card,
    'payments_pay', v_payments_pay,
    'service_count', v_service_count,
    'service_total', v_service_total,
    'staff_meal_count', v_staff_meal_count,
    'staff_meal_total', v_staff_meal_total,
    'discount_total', v_discount_total,
    'orders_completed', v_orders_completed,
    'orders_cancelled', v_orders_cancelled,
    'orders_active', v_orders_active
  );

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_cashier_today_summary(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_cashier_today_summary(uuid) TO authenticated, service_role;

COMMIT;
