-- ============================================================
-- Contract phase: rename active admin table/menu create RPCs to store naming
-- 2026-04-14
-- Scope:
-- - admin_create_table
-- - admin_create_menu_category
-- - admin_create_menu_item
-- Notes:
-- - physical schema still uses restaurant_id during coexistence
-- - contract names move to p_store_id for active create surfaces
-- ============================================================

DROP FUNCTION IF EXISTS public.admin_create_table(uuid, text, int);
DROP FUNCTION IF EXISTS public.admin_create_menu_category(uuid, text, int);
DROP FUNCTION IF EXISTS public.admin_create_menu_item(uuid, uuid, text, numeric, int, text, boolean, boolean);

CREATE OR REPLACE FUNCTION public.admin_create_table(
  p_store_id UUID,
  p_table_number TEXT,
  p_seat_count INT
) RETURNS public.tables AS $$
DECLARE
  v_created public.tables%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  IF NULLIF(btrim(COALESCE(p_table_number, '')), '') IS NULL THEN
    RAISE EXCEPTION 'TABLE_NUMBER_REQUIRED';
  END IF;

  INSERT INTO public.tables (
    restaurant_id,
    table_number,
    seat_count,
    status,
    created_at,
    updated_at
  )
  VALUES (
    p_store_id,
    btrim(p_table_number),
    p_seat_count,
    'available',
    now(),
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_table',
    'tables',
    v_created.id,
    jsonb_build_object(
      'store_id', v_created.restaurant_id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'table_number', v_created.table_number,
        'seat_count', v_created.seat_count,
        'status', v_created.status
      )
    )
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.admin_create_menu_category(
  p_store_id UUID,
  p_name TEXT,
  p_sort_order INT DEFAULT 0
) RETURNS public.menu_categories AS $$
DECLARE
  v_created public.menu_categories%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  IF NULLIF(btrim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NAME_REQUIRED';
  END IF;

  INSERT INTO public.menu_categories (
    restaurant_id,
    name,
    sort_order,
    is_active,
    created_at
  )
  VALUES (
    p_store_id,
    btrim(p_name),
    COALESCE(p_sort_order, 0),
    TRUE,
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_menu_category',
    'menu_categories',
    v_created.id,
    jsonb_build_object(
      'store_id', v_created.restaurant_id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'name', v_created.name,
        'sort_order', v_created.sort_order,
        'is_active', v_created.is_active
      )
    )
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.admin_create_menu_item(
  p_store_id UUID,
  p_category_id UUID,
  p_name TEXT,
  p_price DECIMAL(12,2),
  p_sort_order INT DEFAULT 0,
  p_description TEXT DEFAULT NULL,
  p_is_available BOOLEAN DEFAULT TRUE,
  p_is_visible_public BOOLEAN DEFAULT FALSE
) RETURNS public.menu_items AS $$
DECLARE
  v_created public.menu_items%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  IF NULLIF(btrim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_NAME_REQUIRED';
  END IF;

  IF p_category_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_categories
    WHERE id = p_category_id
      AND restaurant_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  INSERT INTO public.menu_items (
    restaurant_id,
    category_id,
    name,
    description,
    price,
    is_available,
    is_visible_public,
    sort_order,
    created_at,
    updated_at
  )
  VALUES (
    p_store_id,
    p_category_id,
    btrim(p_name),
    NULLIF(btrim(COALESCE(p_description, '')), ''),
    p_price,
    COALESCE(p_is_available, TRUE),
    COALESCE(p_is_visible_public, FALSE),
    COALESCE(p_sort_order, 0),
    now(),
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_menu_item',
    'menu_items',
    v_created.id,
    jsonb_build_object(
      'store_id', v_created.restaurant_id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'category_id', v_created.category_id,
        'name', v_created.name,
        'description', v_created.description,
        'price', v_created.price,
        'is_available', v_created.is_available,
        'is_visible_public', v_created.is_visible_public,
        'sort_order', v_created.sort_order
      )
    )
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
