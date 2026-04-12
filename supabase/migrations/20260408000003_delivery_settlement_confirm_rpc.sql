-- ============================================================
-- Delivery settlement confirmation RPC
-- 2026-04-08
-- Fixes: audit-log omission, client-side timestamp writes,
--        and direct mutation boundary leak on settlement receipt
-- ============================================================

CREATE OR REPLACE FUNCTION confirm_delivery_settlement_received(
  p_settlement_id UUID,
  p_restaurant_id UUID
) RETURNS delivery_settlements AS $$
DECLARE
  v_actor_id UUID := auth.uid();
  v_actor users%ROWTYPE;
  v_settlement delivery_settlements%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = v_actor_id
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'SETTLEMENT_CONFIRM_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_settlement
  FROM delivery_settlements
  WHERE id = p_settlement_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SETTLEMENT_NOT_FOUND';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'SETTLEMENT_CONFIRM_FORBIDDEN';
  END IF;

  IF v_settlement.status <> 'calculated' THEN
    RAISE EXCEPTION 'INVALID_SETTLEMENT_STATUS';
  END IF;

  UPDATE delivery_settlements
  SET status = 'received',
      received_at = now(),
      updated_at = now()
  WHERE id = p_settlement_id
  RETURNING * INTO v_settlement;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    v_actor_id,
    'confirm_delivery_settlement_received',
    'delivery_settlements',
    p_settlement_id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'from_status', 'calculated',
      'to_status', 'received'
    )
  );

  RETURN v_settlement;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
