BEGIN;

-- Menu cancellation retains the existing financial ledger, scope and payment guards.
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
  v_cancelled_amount numeric(15,2);
  v_ledger_id uuid;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'waiter', 'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  SELECT * INTO v_item
  FROM public.order_items
  WHERE id = p_item_id AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND'; END IF;

  SELECT status INTO v_order_status
  FROM public.orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;
  IF EXISTS (SELECT 1 FROM public.payments WHERE order_id = v_item.order_id) THEN
    RAISE EXCEPTION 'ORDER_HAS_PAYMENTS_USE_ADJUSTMENT';
  END IF;
  IF v_item.status NOT IN ('pending', 'preparing', 'ready', 'served') THEN
    RAISE EXCEPTION 'ITEM_NOT_CANCELLABLE';
  END IF;

  -- Cashiers can correct worker progress mistakes without rewriting history.
  -- Waiters retain their served-item restriction.
  IF v_actor.role = 'waiter' AND (
    v_item.status = 'served' OR EXISTS (
      SELECT 1 FROM public.emergency_fulfillment_items
      WHERE order_item_id = p_item_id AND floor_served_quantity > 0
      UNION ALL
      SELECT 1 FROM public.emergency_combo_component_items
      WHERE order_item_id = p_item_id AND floor_served_quantity > 0
      UNION ALL
      SELECT 1 FROM public.emergency_floor_direct_items
      WHERE order_item_id = p_item_id AND floor_served_quantity > 0
    )
  ) THEN RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN'; END IF;

  v_cancelled_amount := CASE
    WHEN v_item.is_service_item THEN 0
    WHEN COALESCE(v_item.paying_amount_inc_tax, 0) > 0
      THEN v_item.paying_amount_inc_tax
    ELSE v_item.unit_price * v_item.quantity
  END;
  v_from_status := v_item.status;

  INSERT INTO public.order_cancellation_ledger (
    restaurant_id, order_id, order_item_id, cancellation_scope,
    cancelled_amount, quantity, unit_price, item_snapshot,
    order_status_snapshot, created_by
  ) VALUES (
    p_store_id, v_item.order_id, v_item.id, 'item',
    v_cancelled_amount, v_item.quantity, v_item.unit_price,
    jsonb_build_array(jsonb_build_object(
      'order_item_id', v_item.id,
      'label', v_item.label,
      'item_type', v_item.item_type,
      'status', v_item.status,
      'quantity', v_item.quantity,
      'unit_price', v_item.unit_price,
      'paying_amount_inc_tax', v_item.paying_amount_inc_tax,
      'is_service_item', v_item.is_service_item
    )),
    v_order_status,
    auth.uid()
  ) RETURNING id INTO v_ledger_id;

  UPDATE public.order_items
  SET status = 'cancelled'
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  PERFORM public.recalc_order_status(v_item.order_id);
  PERFORM public.void_active_order_discount_for_item_change(
    v_item.order_id, p_store_id, 'order_items_changed'
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'cancel_order_item', 'order_items', p_item_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_item.order_id,
      'from_status', v_from_status,
      'to_status', 'cancelled',
      'label', v_item.label,
      'quantity', v_item.quantity,
      'unit_price', v_item.unit_price,
      'cancelled_amount', v_cancelled_amount,
      'cancellation_ledger_id', v_ledger_id
    )
  );

  RETURN v_item;
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_order_item(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_order_item(uuid, uuid) TO authenticated;

-- Keep historical cancellation records and the old implementation for rollback.
REVOKE ALL ON FUNCTION public.cashier_cancel_unserved_v1(
  uuid, uuid, integer, text, uuid
) FROM PUBLIC, anon, authenticated;
CREATE OR REPLACE FUNCTION public.restore_cancelled_order_item(
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
  v_order public.orders%ROWTYPE;
  v_ledger public.order_cancellation_ledger%ROWTYPE;
  v_restore_status text;
BEGIN
  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'waiter', 'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;
  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  SELECT * INTO v_item
  FROM public.order_items
  WHERE id = p_item_id AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND'; END IF;
  IF v_item.status <> 'cancelled' THEN
    RAISE EXCEPTION 'ITEM_NOT_CANCELLED';
  END IF;

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order.status = 'completed' THEN RAISE EXCEPTION 'ORDER_NOT_MUTABLE'; END IF;
  IF EXISTS (SELECT 1 FROM public.payments WHERE order_id = v_item.order_id) THEN
    RAISE EXCEPTION 'ORDER_HAS_PAYMENTS_USE_ADJUSTMENT';
  END IF;
  IF v_order.table_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.table_id = v_order.table_id
      AND o.id <> v_order.id
      AND o.status IN ('pending', 'confirmed', 'serving')
  ) THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  SELECT l.* INTO v_ledger
  FROM public.order_cancellation_ledger l
  LEFT JOIN public.order_cancellation_reversals r
    ON r.cancellation_ledger_id = l.id
  WHERE l.order_item_id = p_item_id
    AND l.restaurant_id = p_store_id
    AND l.cancellation_scope = 'item'
    AND r.id IS NULL
  ORDER BY l.created_at DESC, l.id DESC
  LIMIT 1
  FOR UPDATE OF l;

  IF NOT FOUND THEN RAISE EXCEPTION 'CANCELLATION_NOT_FOUND'; END IF;

  INSERT INTO public.order_cancellation_reversals (
    cancellation_ledger_id, restaurant_id, order_id, order_item_id, restored_by
  ) VALUES (
    v_ledger.id, p_store_id, v_item.order_id, p_item_id, auth.uid()
  );

  v_restore_status := COALESCE(
    NULLIF(v_ledger.item_snapshot->0->>'status', ''), 'pending'
  );
  -- Reopen the order before the item trigger restores its KDS lines.
  IF v_order.status = 'cancelled' THEN
    UPDATE public.orders
    SET status = COALESCE(
      NULLIF(v_ledger.order_status_snapshot, ''), 'confirmed'
    ), updated_at = now()
    WHERE id = v_order.id;
  END IF;

  UPDATE public.order_items
  SET status = v_restore_status
  WHERE id = p_item_id
  RETURNING * INTO v_item;


  PERFORM public.recalc_order_status(v_order.id);
  PERFORM public.void_active_order_discount_for_item_change(
    v_order.id, p_store_id, 'order_items_changed'
  );

  IF v_order.table_id IS NOT NULL THEN
    UPDATE public.tables
    SET status = 'occupied', updated_at = now()
    WHERE id = v_order.table_id;
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'restore_cancelled_order_item', 'order_items', p_item_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_order.id,
      'restored_status', v_restore_status,
      'cancellation_ledger_id', v_ledger.id
    )
  );

  RETURN v_item;
END;
$$;
COMMIT;
