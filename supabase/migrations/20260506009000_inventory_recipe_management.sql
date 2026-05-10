-- ============================================================
-- Inventory Recipe Management RPCs
-- 2026-05-06
--
-- POS-native deletion for menu recipe lines used by inventory purchase UI.
-- Save/update stays on the existing upsert_inventory_recipe_line contract.
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_inventory_recipe_line(
  p_store_id UUID,
  p_recipe_id UUID
) RETURNS UUID AS $$
DECLARE
  v_deleted_id UUID;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_DELETE_FORBIDDEN';
  END IF;

  DELETE FROM public.menu_recipes
  WHERE id = p_recipe_id
    AND restaurant_id = p_store_id
  RETURNING id INTO v_deleted_id;

  IF v_deleted_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_NOT_FOUND';
  END IF;

  RETURN v_deleted_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.delete_inventory_recipe_line(UUID, UUID) TO authenticated;
