-- ============================================================
-- cancel_order RPC v2
-- ROLES.md 기준: pending, confirmed 상태만 취소 가능
-- serving, completed, cancelled 상태는 취소 불가
-- ============================================================
CREATE OR REPLACE FUNCTION cancel_order(
  p_order_id      UUID,
  p_restaurant_id UUID
) RETURNS orders AS $$
DECLARE
  v_order orders;
BEGIN
  SELECT * INTO v_order
  FROM orders
  WHERE id = p_order_id AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  -- ROLES.md: cancelled는 confirmed 이전(pending/confirmed)만 가능
  IF v_order.status NOT IN ('pending', 'confirmed') THEN
    RAISE EXCEPTION 'ORDER_NOT_CANCELLABLE';
  END IF;

  UPDATE orders
  SET status = 'cancelled', updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  -- 테이블 해제
  IF v_order.table_id IS NOT NULL THEN
    UPDATE tables SET status = 'available', updated_at = now()
    WHERE id = v_order.table_id;
  END IF;

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
