-- cancel_order RPC
-- Only cancellable when status is not completed/cancelled.
CREATE OR REPLACE FUNCTION cancel_order(
  p_order_id UUID,
  p_restaurant_id UUID
) RETURNS orders AS $$
DECLARE
  v_order orders;
BEGIN
  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_CANCELLABLE';
  END IF;

  UPDATE orders
  SET status = 'cancelled',
      updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  IF v_order.table_id IS NOT NULL THEN
    UPDATE tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_order.table_id;
  END IF;

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
