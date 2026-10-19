\set ON_ERROR_STOP on

-- Run only after rolling the application back to a build that does not call
-- admin_archive_menu_item. Existing archived rows are intentionally retained.
BEGIN;

DROP FUNCTION IF EXISTS public.admin_archive_menu_item(uuid);

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

  SELECT * INTO v_existing
  FROM public.menu_categories
  WHERE id = p_category_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

  IF EXISTS (
    SELECT 1 FROM public.menu_items item
    WHERE item.category_id = v_existing.id
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_EMPTY';
  END IF;

  DELETE FROM public.menu_categories WHERE id = v_existing.id;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'admin_delete_menu_category', 'menu_categories', v_existing.id,
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

SELECT 'ADMIN_MENU_ITEM_ARCHIVE_ROLLBACK_OK' AS result;
