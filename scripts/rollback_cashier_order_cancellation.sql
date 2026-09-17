BEGIN;
CREATE OR REPLACE FUNCTION public.cancel_order(
  p_order_id uuid,
  p_store_id uuid,
  p_allow_served boolean DEFAULT false
) RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items item
    WHERE item.order_id = p_order_id AND item.floor_served_quantity > 0
    UNION ALL
    SELECT 1 FROM public.emergency_combo_component_items component
    WHERE component.order_id = p_order_id
      AND component.floor_served_quantity > 0
    UNION ALL
    SELECT 1 FROM public.emergency_floor_direct_items direct_item
    WHERE direct_item.order_id = p_order_id
      AND direct_item.floor_served_quantity > 0
  ) THEN
    RAISE EXCEPTION 'ORDER_HAS_SERVED_QUANTITY_CANCEL_UNSERVED_ITEMS';
  END IF;
  RETURN public.cancel_order_pre_start_ready(
    p_order_id, p_store_id, p_allow_served
  );
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_order(uuid, uuid, boolean)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_order(uuid, uuid, boolean)
  TO authenticated;

CREATE OR REPLACE FUNCTION public.restore_cancelled_order(
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
  v_ledger public.order_cancellation_ledger%ROWTYPE;
  v_item jsonb;
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

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  IF v_order.status <> 'cancelled' THEN
    RAISE EXCEPTION 'ORDER_NOT_CANCELLED';
  END IF;
  IF EXISTS (SELECT 1 FROM public.payments WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'ORDER_HAS_PAYMENTS_USE_ADJUSTMENT';
  END IF;
  IF v_order.table_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.table_id = v_order.table_id
      AND o.id <> p_order_id
      AND o.status IN ('pending', 'confirmed', 'serving')
  ) THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  SELECT l.* INTO v_ledger
  FROM public.order_cancellation_ledger l
  LEFT JOIN public.order_cancellation_reversals r
    ON r.cancellation_ledger_id = l.id
  WHERE l.order_id = p_order_id
    AND l.restaurant_id = p_store_id
    AND l.cancellation_scope = 'order'
    AND r.id IS NULL
  ORDER BY l.created_at DESC, l.id DESC
  LIMIT 1
  FOR UPDATE OF l;

  IF NOT FOUND THEN RAISE EXCEPTION 'CANCELLATION_NOT_FOUND'; END IF;

  INSERT INTO public.order_cancellation_reversals (
    cancellation_ledger_id, restaurant_id, order_id, restored_by
  ) VALUES (v_ledger.id, p_store_id, p_order_id, auth.uid());

  FOR v_item IN SELECT value FROM jsonb_array_elements(v_ledger.item_snapshot)
  LOOP
    UPDATE public.order_items
    SET status = COALESCE(NULLIF(v_item->>'status', ''), 'pending')
    WHERE id = (v_item->>'order_item_id')::uuid
      AND order_id = p_order_id
      AND status = 'cancelled';
  END LOOP;

  v_restore_status := COALESCE(
    NULLIF(v_ledger.order_status_snapshot, ''), 'confirmed'
  );
  UPDATE public.orders
  SET status = v_restore_status, updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  UPDATE public.print_jobs
  SET status = 'pending', last_error = NULL, updated_at = now()
  WHERE order_id = p_order_id
    AND status = 'cancelled'
    AND updated_at >= v_ledger.created_at;

  IF v_order.table_id IS NOT NULL THEN
    UPDATE public.tables
    SET status = 'occupied', updated_at = now()
    WHERE id = v_order.table_id;
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'restore_cancelled_order', 'orders', p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'restored_status', v_restore_status,
      'cancellation_ledger_id', v_ledger.id
    )
  );

  RETURN v_order;
END;
$$;

COMMIT;
