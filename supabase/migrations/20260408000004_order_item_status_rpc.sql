-- ============================================================
-- Order item status transition RPC
-- 2026-04-08
-- Fixes: direct mutation boundary leak and missing server-side
--        validation for order_items status transitions
-- ============================================================

CREATE OR REPLACE FUNCTION update_order_item_status(
  p_item_id UUID,
  p_restaurant_id UUID,
  p_new_status TEXT
) RETURNS order_items AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_item order_items%ROWTYPE;
  v_order_status TEXT;
  v_from_status TEXT;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin', 'kitchen') THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_item
  FROM order_items
  WHERE id = p_item_id
    AND restaurant_id = p_restaurant_id
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

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'update_order_item_status',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'from_status', v_from_status,
      'to_status', p_new_status
    )
  );

  RETURN v_item;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
