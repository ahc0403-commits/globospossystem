-- ============================================================
-- POS Inventory Transaction Visibility contract-readiness
-- 2026-04-09
-- Bounded scope:
-- - canonical inventory transaction visibility read
-- - restaurant-scoped date-range filtering
-- - truthful ingredient + transaction fields only
-- Out of scope:
-- - restock / physical count / recipe write flows
-- - reporting redesign
-- - warehouse / accounting expansion
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_inventory_transaction_visibility(
  p_restaurant_id UUID,
  p_from TIMESTAMPTZ,
  p_to TIMESTAMPTZ
) RETURNS TABLE (
  id UUID,
  restaurant_id UUID,
  ingredient_id UUID,
  ingredient_name TEXT,
  ingredient_unit TEXT,
  transaction_type TEXT,
  quantity_g DECIMAL(12,3),
  reference_type TEXT,
  reference_id UUID,
  note TEXT,
  created_at TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_RANGE_REQUIRED';
  END IF;

  IF p_from > p_to THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_RANGE_INVALID';
  END IF;

  RETURN QUERY
  SELECT
    it.id,
    it.restaurant_id,
    it.ingredient_id,
    ii.name AS ingredient_name,
    ii.unit AS ingredient_unit,
    it.transaction_type,
    it.quantity_g,
    it.reference_type,
    it.reference_id,
    it.note,
    it.created_at
  FROM public.inventory_transactions it
  JOIN public.inventory_items ii
    ON ii.id = it.ingredient_id
   AND ii.restaurant_id = it.restaurant_id
  WHERE it.restaurant_id = p_restaurant_id
    AND it.created_at >= p_from
    AND it.created_at <= p_to
  ORDER BY it.created_at DESC, ii.name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
