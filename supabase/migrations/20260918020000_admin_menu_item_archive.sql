-- User-facing menu deletion archives the catalog row so historical orders,
-- fulfillment, recipes, promotions, delivery records, and images keep their
-- stable menu item identity.

BEGIN;

CREATE INDEX IF NOT EXISTS menu_combo_components_restaurant_component_idx
  ON public.menu_combo_components(restaurant_id, component_menu_item_id);

CREATE OR REPLACE FUNCTION public.admin_archive_menu_item(
  p_item_id uuid
) RETURNS public.menu_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_store_id uuid;
  v_existing public.menu_items%ROWTYPE;
  v_updated public.menu_items%ROWTYPE;
BEGIN
  IF p_item_id IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_ID_REQUIRED';
  END IF;

  SELECT item.restaurant_id
  INTO v_store_id
  FROM public.menu_items item
  WHERE item.id = p_item_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_store_id);
  PERFORM pg_advisory_xact_lock(hashtextextended(v_store_id::text, 0));

  SELECT *
  INTO v_existing
  FROM public.menu_items item
  WHERE item.id = p_item_id
    AND item.restaurant_id = v_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  -- A retry from another client is successful without duplicating the audit.
  IF v_existing.is_archived THEN
    RETURN v_existing;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.menu_combo_components component
    JOIN public.menu_items combo
      ON combo.id = component.combo_menu_item_id
     AND combo.restaurant_id = component.restaurant_id
    WHERE component.component_menu_item_id = v_existing.id
      AND component.restaurant_id = v_existing.restaurant_id
      AND combo.is_archived = false
  ) THEN
    RAISE EXCEPTION 'MENU_COMBO_COMPONENT_IN_USE';
  END IF;

  UPDATE public.menu_items
  SET is_archived = true,
      is_available = false,
      is_visible_public = false,
      updated_at = now()
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_menu_item',
    'menu_items',
    v_updated.id,
    jsonb_build_object(
      'store_id', v_updated.restaurant_id,
      'restaurant_id', v_updated.restaurant_id,
      'delete_mode', 'archive',
      'archived_at_utc', now(),
      'old_values', jsonb_build_object(
        'category_id', v_existing.category_id,
        'name', v_existing.name,
        'is_archived', v_existing.is_archived,
        'is_available', v_existing.is_available,
        'is_visible_public', v_existing.is_visible_public,
        'sort_order', v_existing.sort_order,
        'image_url', v_existing.image_url,
        'image_storage_path', v_existing.image_storage_path
      ),
      'new_values', jsonb_build_object(
        'is_archived', v_updated.is_archived,
        'is_available', v_updated.is_available,
        'is_visible_public', v_updated.is_visible_public
      )
    )
  );

  RETURN v_updated;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_archive_menu_item(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_archive_menu_item(uuid)
  TO authenticated, service_role;

-- Archived items do not keep an otherwise empty category from being deleted.
-- The existing category FK uses ON DELETE SET NULL, so archived item identity
-- remains intact when its former category is removed.
CREATE OR REPLACE FUNCTION public.admin_delete_menu_category(
  p_category_id uuid
) RETURNS public.menu_categories
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_existing public.menu_categories%ROWTYPE;
BEGIN
  IF p_category_id IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_categories
  WHERE id = p_category_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

  IF EXISTS (
    SELECT 1
    FROM public.menu_items item
    WHERE item.category_id = v_existing.id
      AND item.is_archived = false
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_EMPTY';
  END IF;

  DELETE FROM public.menu_categories
  WHERE id = v_existing.id;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_menu_category',
    'menu_categories',
    v_existing.id,
    jsonb_build_object(
      'store_id', v_existing.restaurant_id,
      'deleted_at_utc', now(),
      'old_values', jsonb_build_object(
        'name', v_existing.name,
        'sort_order', v_existing.sort_order,
        'is_active', v_existing.is_active
      )
    )
  );

  RETURN v_existing;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_delete_menu_category(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_menu_category(uuid)
  TO authenticated, service_role;

COMMIT;
