-- Allow cashier cancellation of unpaid orders regardless of worker progress.
BEGIN;

CREATE OR REPLACE FUNCTION public.cancel_order(
  p_order_id uuid,
  p_store_id uuid,
  p_allow_served boolean DEFAULT false
) RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_from_status text;
  v_cancelled_items int := 0;
  v_cancelled_amount numeric(15,2) := 0;
  v_item_snapshot jsonb := '[]'::jsonb;
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

  SELECT * INTO v_order
  FROM public.orders
  WHERE id = p_order_id AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_CANCELLABLE';
  END IF;
  IF EXISTS (SELECT 1 FROM public.payments WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'ORDER_HAS_PAYMENTS_USE_ADJUSTMENT';
  END IF;
  IF v_order.status = 'serving'
     AND v_actor.role NOT IN (
       'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
     ) THEN
    RAISE EXCEPTION 'ORDER_SERVING_CANCEL_ADMIN_REQUIRED';
  END IF;
  -- Worker progress is not a financial lock. Only cashier/management may
  -- override it; the legacy client flag must never grant a waiter permission.
  IF v_actor.role = 'waiter' AND (
    EXISTS (SELECT 1 FROM public.order_items
      WHERE order_id = p_order_id AND status = 'served')
    OR EXISTS (SELECT 1 FROM public.emergency_fulfillment_items
      WHERE order_id = p_order_id AND floor_served_quantity > 0)
    OR EXISTS (SELECT 1 FROM public.emergency_combo_component_items
      WHERE order_id = p_order_id AND floor_served_quantity > 0)
    OR EXISTS (SELECT 1 FROM public.emergency_floor_direct_items
      WHERE order_id = p_order_id AND floor_served_quantity > 0)
  ) THEN
    RAISE EXCEPTION 'ORDER_HAS_SERVED_ITEMS';
  END IF;

  SELECT
    COALESCE(sum(
      CASE
        WHEN oi.is_service_item THEN 0
        WHEN COALESCE(oi.paying_amount_inc_tax, 0) > 0
          THEN oi.paying_amount_inc_tax
        ELSE oi.unit_price * oi.quantity
      END
    ), 0)::numeric(15,2),
    COALESCE(jsonb_agg(
      jsonb_build_object(
        'order_item_id', oi.id,
        'label', oi.label,
        'item_type', oi.item_type,
        'status', oi.status,
        'quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'paying_amount_inc_tax', oi.paying_amount_inc_tax,
        'is_service_item', oi.is_service_item
      ) ORDER BY oi.created_at, oi.id
    ), '[]'::jsonb)
  INTO v_cancelled_amount, v_item_snapshot
  FROM public.order_items oi
  WHERE oi.order_id = p_order_id AND oi.status <> 'cancelled';

  v_from_status := v_order.status;
  INSERT INTO public.order_cancellation_ledger (
    restaurant_id, order_id, cancellation_scope, cancelled_amount,
    item_snapshot, order_status_snapshot, created_by
  ) VALUES (
    p_store_id, p_order_id, 'order', v_cancelled_amount,
    v_item_snapshot, v_from_status, auth.uid()
  ) RETURNING id INTO v_ledger_id;

  UPDATE public.order_items
  SET status = 'cancelled'
  WHERE order_id = p_order_id AND status IN ('pending', 'preparing', 'ready', 'served');
  GET DIAGNOSTICS v_cancelled_items = ROW_COUNT;

  UPDATE public.orders
  SET status = 'cancelled', updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  UPDATE public.print_jobs
  SET status = 'cancelled', updated_at = now()
  WHERE order_id = p_order_id AND status IN ('pending', 'failed');

  IF v_order.table_id IS NOT NULL THEN
    UPDATE public.tables
    SET status = 'available', updated_at = now()
    WHERE id = v_order.table_id
      AND NOT EXISTS (
        SELECT 1 FROM public.orders o
        WHERE o.table_id = v_order.table_id
          AND o.id <> p_order_id
          AND o.status IN ('pending', 'confirmed', 'serving')
      );
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'cancel_order', 'orders', p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'from_status', v_from_status,
      'to_status', 'cancelled',
      'cancelled_item_count', v_cancelled_items,
      'cancelled_amount', v_cancelled_amount,
      'cancellation_ledger_id', v_ledger_id
    )
  );

  RETURN v_order;
END;
$$;

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

  -- Reopen the parent first so item triggers reactivate every KDS route.
  v_restore_status := COALESCE(
    NULLIF(v_ledger.order_status_snapshot, ''), 'confirmed'
  );
  UPDATE public.orders
  SET status = v_restore_status, updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  FOR v_item IN SELECT value FROM jsonb_array_elements(v_ledger.item_snapshot)
  LOOP
    UPDATE public.order_items
    SET status = COALESCE(NULLIF(v_item->>'status', ''), 'pending')
    WHERE id = (v_item->>'order_item_id')::uuid
      AND order_id = p_order_id
      AND status = 'cancelled';
  END LOOP;


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

REVOKE ALL ON FUNCTION public.cancel_order(uuid, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_order(uuid, uuid, boolean) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.restore_cancelled_order(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.restore_cancelled_order(uuid, uuid) TO authenticated, service_role;
COMMIT;
