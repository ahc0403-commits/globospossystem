-- Minimal catalog facades for the focused migration test; the additional current
-- schema suite separately exercises the real production wrappers and invoice ACLs.
CREATE TABLE public.menu_recipes(restaurant_id uuid,menu_item_id uuid,ingredient_id uuid,quantity_g numeric);
CREATE TABLE public.menu_combo_components(restaurant_id uuid,combo_menu_item_id uuid,component_menu_item_id uuid,quantity numeric);
CREATE TABLE public.store_promotion_menu_items(menu_item_id uuid);
CREATE FUNCTION public.direct_order_public_storefront_pre_options(p_slug text) RETURNS jsonb LANGUAGE sql AS $$
 SELECT jsonb_build_object('items',coalesce(jsonb_agg(to_jsonb(menu)),'[]')) FROM public.menu_items menu
 WHERE menu.restaurant_id=p_slug::uuid AND menu.is_available = true;
$$;
CREATE FUNCTION public.direct_order_public_storefront_v3_pre_options(p_slug text,p_after_sort integer,p_after_id uuid,p_limit integer)
RETURNS jsonb LANGUAGE sql AS $$
 SELECT jsonb_build_object('items',coalesce(jsonb_agg(to_jsonb(m)),'[]')) FROM public.menu_items m
 WHERE m.is_available AND m.is_visible_public AND NOT m.is_archived AND (m.category_id IS NULL OR m.restaurant_id=p_slug::uuid);
$$;
CREATE FUNCTION public.qr_get_menu_pre_takeout_availability(p_slug text) RETURNS jsonb LANGUAGE sql AS $$
 SELECT jsonb_build_object('items',coalesce(jsonb_agg(to_jsonb(menu)),'[]')) FROM public.menu_items menu
 WHERE menu.restaurant_id=p_slug::uuid AND menu.is_available = true;
$$;
