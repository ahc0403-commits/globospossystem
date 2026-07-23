BEGIN;

CREATE OR REPLACE FUNCTION public.get_inventory_ingredient_catalog(
  p_store_id uuid
) RETURNS TABLE (
  id uuid,
  restaurant_id uuid,
  name text,
  unit text,
  current_stock numeric,
  reorder_point numeric,
  cost_per_unit numeric,
  supplier_name text,
  needs_reorder boolean,
  last_updated timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'admin',
    'store_admin',
    'brand_admin',
    'super_admin',
    'photo_objet_master',
    'photo_objet_store_operator'
  ) THEN
    RAISE EXCEPTION 'INVENTORY_CATALOG_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) scope(store_id)
       WHERE scope.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'INVENTORY_CATALOG_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    item.id,
    item.restaurant_id,
    item.name,
    item.unit,
    item.current_stock,
    item.reorder_point,
    item.cost_per_unit,
    item.supplier_name,
    item.reorder_point IS NOT NULL
      AND item.current_stock <= item.reorder_point AS needs_reorder,
    item.updated_at AS last_updated
  FROM public.inventory_items item
  WHERE item.restaurant_id = p_store_id
  ORDER BY lower(item.name), item.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.get_inventory_ingredient_catalog(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_ingredient_catalog(uuid)
  TO authenticated;

COMMENT ON FUNCTION public.get_inventory_ingredient_catalog(uuid) IS
  'Returns the active store inventory catalog to authorized store, brand, and Photo Objet managers.';

COMMIT;
