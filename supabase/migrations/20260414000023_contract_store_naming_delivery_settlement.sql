BEGIN;

DROP FUNCTION IF EXISTS public.confirm_delivery_settlement_received(uuid, uuid);

CREATE OR REPLACE FUNCTION public.confirm_delivery_settlement_received(
  p_settlement_id uuid,
  p_store_id uuid
) RETURNS delivery_settlements AS $$
DECLARE
  v_actor_id uuid := auth.uid();
  v_actor users%ROWTYPE;
  v_settlement delivery_settlements%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = v_actor_id
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'SETTLEMENT_CONFIRM_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'SETTLEMENT_STORE_REQUIRED';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'SETTLEMENT_CONFIRM_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_settlement
  FROM delivery_settlements
  WHERE id = p_settlement_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SETTLEMENT_NOT_FOUND';
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
      'store_id', p_store_id,
      'from_status', 'calculated',
      'to_status', 'received'
    )
  );

  RETURN v_settlement;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

COMMIT;
