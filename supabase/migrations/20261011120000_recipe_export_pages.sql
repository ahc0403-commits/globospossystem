BEGIN;
CREATE INDEX IF NOT EXISTS menu_recipes_store_export_id_idx ON public.menu_recipes(restaurant_id,id);
CREATE INDEX IF NOT EXISTS menu_items_store_export_id_idx ON public.menu_items(restaurant_id,id);
CREATE INDEX IF NOT EXISTS inventory_products_store_export_id_idx ON public.inventory_products(restaurant_id,id);
-- Preserve the recipe catalog's explicit store-access boundary while exporting
-- flat, bounded pages. Both joins below are many-to-one primary-key joins.
CREATE OR REPLACE FUNCTION public.get_inventory_recipe_export_page(
  p_store_id uuid, p_source text, p_after_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 500
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,auth,pg_catalog AS $$
DECLARE v_rows jsonb; v_more boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_FORBIDDEN';
  END IF;
  IF p_source IS NULL OR p_source NOT IN ('recipes','menus','ingredients')
    OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_EXPORT_QUERY_INVALID';
  END IF;
  IF p_source='recipes' THEN
    SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.id),'[]') INTO v_rows FROM (
      SELECT r.id,r.restaurant_id,m.name AS menu_item_name,
        i.name AS ingredient_name,r.quantity_g
      FROM public.menu_recipes r
      JOIN public.menu_items m ON m.id=r.menu_item_id AND m.restaurant_id=r.restaurant_id
      JOIN public.inventory_items i ON i.id=r.ingredient_id AND i.restaurant_id=r.restaurant_id
      WHERE r.restaurant_id=p_store_id AND (p_after_id IS NULL OR r.id>p_after_id)
      ORDER BY r.id LIMIT p_limit+1
    )q;
  ELSIF p_source='menus' THEN
    SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.id),'[]') INTO v_rows FROM (
      SELECT m.id,m.restaurant_id,m.name FROM public.menu_items m
      WHERE m.restaurant_id=p_store_id AND (p_after_id IS NULL OR m.id>p_after_id)
        AND NULLIF(btrim(m.name),'') IS NOT NULL
      ORDER BY m.id LIMIT p_limit+1
    )q;
  ELSE
    SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.id),'[]') INTO v_rows FROM (
      SELECT p.id,p.restaurant_id,p.name,p.base_unit FROM public.inventory_products p
      WHERE p.restaurant_id=p_store_id AND (p_after_id IS NULL OR p.id>p_after_id)
        AND p.inventory_item_id IS NOT NULL AND p.is_active
        AND lower(p.base_unit) IN ('g','ml','ea')
      ORDER BY p.id LIMIT p_limit+1
    )q;
  END IF;
  v_more:=jsonb_array_length(v_rows)>p_limit;
  IF v_more THEN v_rows:=v_rows-p_limit; END IF;
  RETURN jsonb_build_object('version',1,'rows',v_rows,'has_more',v_more);
END $$;
REVOKE ALL ON FUNCTION public.get_inventory_recipe_export_page(uuid,text,uuid,integer)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_inventory_recipe_export_page(uuid,text,uuid,integer)
  TO authenticated;
COMMIT;
