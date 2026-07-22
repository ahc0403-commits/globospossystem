-- Kitchen no longer exposes a separate ready/handoff step. Individual items
-- can move directly from cooking to served, while pending items still require
-- an explicit cooking start.
CREATE OR REPLACE FUNCTION public.update_order_item_status(
  p_item_id uuid,
  p_store_id uuid,
  p_new_status text
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
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'super_admin', 'kitchen') THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  SELECT * INTO v_item
  FROM public.order_items
  WHERE id = p_item_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND'; END IF;

  SELECT status INTO v_order_status
  FROM public.orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;
  IF v_item.status = 'cancelled' THEN
    RAISE EXCEPTION 'ITEM_IS_CANCELLED';
  END IF;

  IF NOT (
    (v_item.status = 'pending' AND p_new_status = 'preparing')
    OR (v_item.status = 'preparing' AND p_new_status = 'served')
    OR (v_item.status = 'ready' AND p_new_status = 'served')
    OR v_item.status = p_new_status
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_STATUS_TRANSITION';
  END IF;

  v_from_status := v_item.status;
  UPDATE public.order_items
  SET status = p_new_status
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  PERFORM public.recalc_order_status(v_item.order_id);

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'update_order_item_status', 'order_items', p_item_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_item.order_id,
      'from_status', v_from_status,
      'to_status', p_new_status,
      'order_status_after', (
        SELECT status FROM public.orders WHERE id = v_item.order_id
      )
    )
  );

  RETURN v_item;
END;
$$;

-- Complete every active food item on one table ticket atomically.
CREATE OR REPLACE FUNCTION public.complete_kitchen_order(
  p_order_id uuid,
  p_store_id uuid
) RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_completed_count int := 0;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'super_admin', 'kitchen') THEN
    RAISE EXCEPTION 'KITCHEN_ORDER_COMPLETE_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'KITCHEN_ORDER_COMPLETE_FORBIDDEN';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  UPDATE public.order_items
  SET status = 'served'
  WHERE order_id = p_order_id
    AND restaurant_id = p_store_id
    AND status IN ('pending', 'preparing', 'ready');
  GET DIAGNOSTICS v_completed_count = ROW_COUNT;

  IF v_completed_count = 0 THEN
    RAISE EXCEPTION 'KITCHEN_ORDER_HAS_NO_ACTIVE_ITEMS';
  END IF;

  PERFORM public.recalc_order_status(p_order_id);
  SELECT * INTO v_order FROM public.orders WHERE id = p_order_id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'complete_kitchen_order', 'orders', p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'completed_item_count', v_completed_count,
      'order_status_after', v_order.status
    )
  );

  RETURN v_order;
END;
$$;

REVOKE ALL ON FUNCTION public.complete_kitchen_order(uuid, uuid)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_kitchen_order(uuid, uuid)
TO authenticated, service_role;
