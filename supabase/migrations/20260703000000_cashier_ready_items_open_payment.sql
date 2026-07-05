BEGIN;

CREATE OR REPLACE FUNCTION public.update_order_item_status(
  p_item_id uuid,
  p_store_id uuid,
  p_new_status text
) RETURNS order_items AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_item order_items%ROWTYPE;
  v_order_status text;
  v_from_status text;
  v_next_order_status text;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'super_admin', 'kitchen') THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_item
  FROM order_items
  WHERE id = p_item_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  SELECT status
  INTO v_order_status
  FROM orders
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
    OR (v_item.status = 'preparing' AND p_new_status = 'ready')
    OR (v_item.status = 'ready' AND p_new_status = 'served')
    OR v_item.status = p_new_status
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_STATUS_TRANSITION';
  END IF;

  v_from_status := v_item.status;

  UPDATE order_items
  SET status = p_new_status
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  IF NOT EXISTS (
    SELECT 1
    FROM order_items oi
    WHERE oi.order_id = v_item.order_id
      AND oi.status <> 'cancelled'
      AND oi.status NOT IN ('ready', 'served')
  ) THEN
    v_next_order_status := 'serving';
  ELSIF p_new_status IN ('preparing', 'ready') AND v_order_status = 'pending' THEN
    v_next_order_status := 'confirmed';
  ELSE
    v_next_order_status := v_order_status;
  END IF;

  IF v_next_order_status <> v_order_status THEN
    UPDATE orders
    SET status = v_next_order_status,
        updated_at = now()
    WHERE id = v_item.order_id
      AND status NOT IN ('completed', 'cancelled');
  ELSE
    UPDATE orders
    SET updated_at = now()
    WHERE id = v_item.order_id
      AND status NOT IN ('completed', 'cancelled');
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'update_order_item_status',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_item.order_id,
      'from_status', v_from_status,
      'to_status', p_new_status,
      'order_status_after', v_next_order_status
    )
  );

  RETURN v_item;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

UPDATE orders o
SET status = 'serving',
    updated_at = now()
WHERE o.status IN ('pending', 'confirmed')
  AND EXISTS (
    SELECT 1
    FROM order_items oi
    WHERE oi.order_id = o.id
      AND oi.status <> 'cancelled'
  )
  AND NOT EXISTS (
    SELECT 1
    FROM order_items oi
    WHERE oi.order_id = o.id
      AND oi.status <> 'cancelled'
      AND oi.status NOT IN ('ready', 'served')
  );

COMMIT;
