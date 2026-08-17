BEGIN;

-- production-gate: self-verifying

-- Cashiers already open the discount surface without an extra permission.
-- Line-level service remains manager-approved through the store PIN, store
-- scope, immutable audit log, and pre-payment guards below.
CREATE OR REPLACE FUNCTION public.mark_order_item_service(
  p_item_id uuid,
  p_store_id uuid,
  p_reason text,
  p_manager_pin text
) RETURNS public.order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_order public.orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND
     OR v_actor.role NOT IN (
       'cashier',
       'admin',
       'store_admin',
       'brand_admin',
       'super_admin'
     ) THEN
    RAISE EXCEPTION 'SERVICE_MARK_FORBIDDEN';
  END IF;

  IF p_item_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'SERVICE_MARK_ITEM_REQUIRED';
  END IF;

  IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'SERVICE_REASON_REQUIRED';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'SERVICE_MARK_FORBIDDEN';
  END IF;

  PERFORM public.verify_discount_manager_pin_or_raise(
    p_store_id,
    p_manager_pin,
    'mark_order_item_service'
  );

  SELECT *
  INTO v_item
  FROM public.order_items
  WHERE id = p_item_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  IF v_item.item_type <> 'menu_item' THEN
    RAISE EXCEPTION 'SERVICE_MARK_ITEM_TYPE';
  END IF;

  IF v_item.status = 'cancelled' THEN
    RAISE EXCEPTION 'SERVICE_MARK_ITEM_CANCELLED';
  END IF;

  IF COALESCE(v_item.is_service_item, false) THEN
    RAISE EXCEPTION 'SERVICE_MARK_ALREADY';
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = v_item.order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF COALESCE(v_order.order_purpose, 'customer') = 'staff_meal' THEN
    RAISE EXCEPTION 'SERVICE_MARK_PURPOSE_UNSUPPORTED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.payments p
    WHERE p.order_id = v_order.id
  ) THEN
    RAISE EXCEPTION 'SERVICE_MARK_AFTER_PAYMENT';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.order_items oi
    WHERE oi.order_id = v_order.id
      AND oi.restaurant_id = p_store_id
      AND oi.id <> p_item_id
      AND oi.status <> 'cancelled'
      AND oi.item_type = 'menu_item'
      AND COALESCE(oi.is_service_item, false) = false
  ) THEN
    RAISE EXCEPTION 'FULL_SERVICE_NOT_ALLOWED';
  END IF;

  UPDATE public.order_items
  SET is_service_item = true,
      service_reason = btrim(p_reason),
      service_marked_by = auth.uid(),
      service_marked_at = now(),
      vat_rate = 0,
      vat_amount = 0,
      total_amount_ex_tax = 0,
      paying_amount_inc_tax = 0
  WHERE id = v_item.id
  RETURNING * INTO v_item;

  PERFORM public.void_active_order_discount_for_item_change(
    v_order.id,
    p_store_id,
    'order_items_changed'
  );

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  )
  VALUES (
    auth.uid(),
    'mark_order_item_service',
    'order_items',
    v_item.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_order.id,
      'reason', btrim(p_reason),
      'label', COALESCE(v_item.display_name, v_item.label),
      'quantity', v_item.quantity,
      'unit_price', v_item.unit_price
    )
  );

  RETURN v_item;
END;
$$;

CREATE OR REPLACE FUNCTION public.unmark_order_item_service(
  p_item_id uuid,
  p_store_id uuid,
  p_reason text,
  p_manager_pin text
) RETURNS public.order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_order public.orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND
     OR v_actor.role NOT IN (
       'cashier',
       'admin',
       'store_admin',
       'brand_admin',
       'super_admin'
     ) THEN
    RAISE EXCEPTION 'SERVICE_MARK_FORBIDDEN';
  END IF;

  IF p_item_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'SERVICE_MARK_ITEM_REQUIRED';
  END IF;

  IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'SERVICE_REASON_REQUIRED';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'SERVICE_MARK_FORBIDDEN';
  END IF;

  PERFORM public.verify_discount_manager_pin_or_raise(
    p_store_id,
    p_manager_pin,
    'unmark_order_item_service'
  );

  SELECT *
  INTO v_item
  FROM public.order_items
  WHERE id = p_item_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  IF v_item.item_type <> 'menu_item' THEN
    RAISE EXCEPTION 'SERVICE_MARK_ITEM_TYPE';
  END IF;

  IF NOT COALESCE(v_item.is_service_item, false) THEN
    RAISE EXCEPTION 'SERVICE_MARK_NOT_SET';
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = v_item.order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF COALESCE(v_order.order_purpose, 'customer') = 'staff_meal' THEN
    RAISE EXCEPTION 'SERVICE_MARK_PURPOSE_UNSUPPORTED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.payments p
    WHERE p.order_id = v_order.id
  ) THEN
    RAISE EXCEPTION 'SERVICE_MARK_AFTER_PAYMENT';
  END IF;

  UPDATE public.order_items
  SET is_service_item = false,
      service_reason = NULL,
      service_marked_by = NULL,
      service_marked_at = NULL
  WHERE id = v_item.id
  RETURNING * INTO v_item;

  PERFORM public.void_active_order_discount_for_item_change(
    v_order.id,
    p_store_id,
    'order_items_changed'
  );

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  )
  VALUES (
    auth.uid(),
    'unmark_order_item_service',
    'order_items',
    v_item.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_order.id,
      'reason', btrim(p_reason),
      'label', COALESCE(v_item.display_name, v_item.label),
      'quantity', v_item.quantity,
      'unit_price', v_item.unit_price
    )
  );

  RETURN v_item;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_order_item_service(uuid, uuid, text, text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.unmark_order_item_service(uuid, uuid, text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_order_item_service(uuid, uuid, text, text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.unmark_order_item_service(uuid, uuid, text, text)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.mark_order_item_service(uuid, uuid, text, text) IS
  'Marks one non-cancelled menu line as manager-approved free service before payment; cashier access is authorized by store scope and manager PIN.';

DO $verify$
DECLARE
  v_mark_definition text;
  v_unmark_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.mark_order_item_service(uuid,uuid,text,text)'::regprocedure
  ) INTO v_mark_definition;
  SELECT pg_get_functiondef(
    'public.unmark_order_item_service(uuid,uuid,text,text)'::regprocedure
  ) INTO v_unmark_definition;

  IF v_mark_definition NOT LIKE '%v_actor.role NOT IN (%''cashier''%'
     OR v_unmark_definition NOT LIKE '%v_actor.role NOT IN (%''cashier''%' THEN
    RAISE EXCEPTION 'cashier service-item role access verification failed';
  END IF;

  IF v_mark_definition NOT LIKE '%verify_discount_manager_pin_or_raise%'
     OR v_unmark_definition NOT LIKE '%verify_discount_manager_pin_or_raise%' THEN
    RAISE EXCEPTION 'service-item manager PIN verification is missing';
  END IF;

  IF v_mark_definition LIKE '%SERVICE_MARK_ITEM_NOT_PROVIDED%' THEN
    RAISE EXCEPTION 'service-item pending-line compatibility was not applied';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.mark_order_item_service(uuid,uuid,text,text)'::regprocedure,
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated service-item RPC access is missing';
  END IF;
END;
$verify$;

COMMIT;
