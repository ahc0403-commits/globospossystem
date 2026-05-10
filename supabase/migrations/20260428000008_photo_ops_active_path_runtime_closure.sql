BEGIN;

DROP FUNCTION IF EXISTS public.get_attendance_log_view(UUID, TIMESTAMPTZ, TIMESTAMPTZ, UUID);
DROP FUNCTION IF EXISTS public.get_inventory_ingredient_catalog(UUID);

CREATE OR REPLACE FUNCTION public.get_attendance_log_view(
  p_store_id UUID,
  p_from TIMESTAMPTZ,
  p_to TIMESTAMPTZ,
  p_user_id UUID DEFAULT NULL
) RETURNS TABLE (
  attendance_log_id UUID,
  restaurant_id UUID,
  user_id UUID,
  user_full_name TEXT,
  user_role TEXT,
  attendance_type TEXT,
  photo_url TEXT,
  photo_thumbnail_url TEXT,
  logged_at TIMESTAMPTZ,
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

  IF NOT FOUND OR v_actor.role NOT IN (
    'admin',
    'store_admin',
    'brand_admin',
    'super_admin',
    'photo_objet_master',
    'photo_objet_store_admin'
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_VIEW_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_VIEW_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_RANGE_REQUIRED';
  END IF;

  IF p_from > p_to THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_RANGE_INVALID';
  END IF;

  IF p_user_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = p_user_id
      AND u.restaurant_id = p_store_id
      AND u.is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_LOG_USER_NOT_FOUND';
  END IF;

  RETURN QUERY
  SELECT
    al.id AS attendance_log_id,
    al.restaurant_id,
    al.user_id,
    u.full_name AS user_full_name,
    u.role AS user_role,
    al.type AS attendance_type,
    al.photo_url,
    al.photo_thumbnail_url,
    al.logged_at,
    al.created_at
  FROM public.attendance_logs al
  JOIN public.users u
    ON u.id = al.user_id
   AND u.restaurant_id = al.restaurant_id
  WHERE al.restaurant_id = p_store_id
    AND al.logged_at >= p_from
    AND al.logged_at <= p_to
    AND (p_user_id IS NULL OR al.user_id = p_user_id)
  ORDER BY al.logged_at DESC, al.created_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.get_inventory_ingredient_catalog(
  p_store_id UUID
) RETURNS TABLE (
  id UUID,
  restaurant_id UUID,
  name TEXT,
  unit TEXT,
  current_stock DECIMAL(12,3),
  reorder_point DECIMAL(12,3),
  cost_per_unit DECIMAL(12,2),
  supplier_name TEXT,
  needs_reorder BOOLEAN,
  last_updated TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'admin',
    'store_admin',
    'brand_admin',
    'super_admin',
    'photo_objet_master',
    'photo_objet_store_admin'
  ) THEN
    RAISE EXCEPTION 'INVENTORY_CATALOG_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'INVENTORY_CATALOG_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    ii.id,
    ii.restaurant_id,
    ii.name,
    ii.unit,
    ii.current_stock,
    ii.reorder_point,
    ii.cost_per_unit,
    ii.supplier_name,
    CASE
      WHEN ii.reorder_point IS NOT NULL AND ii.current_stock <= ii.reorder_point
        THEN TRUE
      ELSE FALSE
    END AS needs_reorder,
    ii.updated_at AS last_updated
  FROM public.inventory_items ii
  WHERE ii.restaurant_id = p_store_id
  ORDER BY lower(ii.name), ii.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

COMMIT;
