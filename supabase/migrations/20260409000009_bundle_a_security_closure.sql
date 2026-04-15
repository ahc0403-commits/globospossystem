-- ============================================================
-- Bundle A security closure
-- 2026-04-09
-- Scope:
-- - close unaudited users write boundary
-- - tighten privileged table write policies
-- - remove client-authenticated delivery inserts
-- - disable dormant fingerprint client access
-- ============================================================

-- ============================================================
-- users: read remains restaurant-scoped, direct authenticated writes removed
-- ============================================================
DROP POLICY IF EXISTS users_policy ON public.users;
CREATE POLICY users_select_policy ON public.users
FOR SELECT TO authenticated
USING (
  is_super_admin()
  OR restaurant_id = get_user_restaurant_id()
);
CREATE OR REPLACE FUNCTION public.update_my_profile_full_name(
  p_full_name TEXT
) RETURNS public.users AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_updated public.users%ROWTYPE;
  v_full_name TEXT := NULLIF(btrim(COALESCE(p_full_name, '')), '');
BEGIN
  IF v_full_name IS NULL THEN
    RAISE EXCEPTION 'USER_FULL_NAME_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'USER_PROFILE_UPDATE_FORBIDDEN';
  END IF;

  UPDATE public.users
  SET full_name = v_full_name
  WHERE id = v_actor.id
  RETURNING * INTO v_updated;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
CREATE OR REPLACE FUNCTION public.admin_update_staff_account(
  p_user_id UUID,
  p_restaurant_id UUID,
  p_full_name TEXT DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT NULL,
  p_extra_permissions TEXT[] DEFAULT NULL
) RETURNS public.users AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_target public.users%ROWTYPE;
  v_updated public.users%ROWTYPE;
  v_full_name TEXT := NULLIF(btrim(COALESCE(p_full_name, '')), '');
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  IF p_user_id IS NULL OR p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_INVALID';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_target
  FROM public.users
  WHERE id = p_user_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_NOT_FOUND';
  END IF;

  IF v_actor.role = 'admin'
     AND v_target.role IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  IF p_full_name IS NOT NULL THEN
    IF v_full_name IS NULL THEN
      RAISE EXCEPTION 'USER_FULL_NAME_REQUIRED';
    END IF;
    IF v_full_name IS DISTINCT FROM v_target.full_name THEN
      v_changed_fields := array_append(v_changed_fields, 'full_name');
      v_old_values := v_old_values || jsonb_build_object('full_name', v_target.full_name);
      v_new_values := v_new_values || jsonb_build_object('full_name', v_full_name);
    END IF;
  ELSE
    v_full_name := v_target.full_name;
  END IF;

  IF p_is_active IS NOT NULL AND p_is_active IS DISTINCT FROM v_target.is_active THEN
    v_changed_fields := array_append(v_changed_fields, 'is_active');
    v_old_values := v_old_values || jsonb_build_object('is_active', v_target.is_active);
    v_new_values := v_new_values || jsonb_build_object('is_active', p_is_active);
  END IF;

  IF p_extra_permissions IS NOT NULL
     AND COALESCE(p_extra_permissions, ARRAY[]::TEXT[]) IS DISTINCT FROM COALESCE(v_target.extra_permissions, ARRAY[]::TEXT[]) THEN
    v_changed_fields := array_append(v_changed_fields, 'extra_permissions');
    v_old_values := v_old_values || jsonb_build_object('extra_permissions', COALESCE(v_target.extra_permissions, ARRAY[]::TEXT[]));
    v_new_values := v_new_values || jsonb_build_object('extra_permissions', COALESCE(p_extra_permissions, ARRAY[]::TEXT[]));
  END IF;

  UPDATE public.users
  SET full_name = v_full_name,
      is_active = COALESCE(p_is_active, v_target.is_active),
      extra_permissions = CASE
        WHEN p_extra_permissions IS NULL THEN v_target.extra_permissions
        ELSE COALESCE(p_extra_permissions, ARRAY[]::TEXT[])
      END
  WHERE id = v_target.id
  RETURNING * INTO v_updated;

  IF array_length(v_changed_fields, 1) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_staff_account',
      'users',
      v_updated.id,
      jsonb_build_object(
        'restaurant_id', v_updated.restaurant_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values
      )
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
CREATE OR REPLACE FUNCTION public.complete_onboarding_account_setup(
  p_restaurant_id UUID,
  p_full_name TEXT,
  p_role TEXT
) RETURNS public.users AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_updated public.users%ROWTYPE;
  v_full_name TEXT := NULLIF(btrim(COALESCE(p_full_name, '')), '');
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'ONBOARDING_RESTAURANT_REQUIRED';
  END IF;

  IF v_full_name IS NULL THEN
    RAISE EXCEPTION 'USER_FULL_NAME_REQUIRED';
  END IF;

  IF p_role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'ONBOARDING_ROLE_INVALID';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'ONBOARDING_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  UPDATE public.users
  SET restaurant_id = p_restaurant_id,
      full_name = v_full_name,
      role = p_role
  WHERE id = v_actor.id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'complete_onboarding_account_setup',
    'users',
    v_updated.id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'new_role', p_role
    )
  );

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
-- ============================================================
-- restaurants: writes limited to admin/super_admin or super_admin only
-- ============================================================
DROP POLICY IF EXISTS restaurants_policy ON public.restaurants;
CREATE POLICY restaurants_select_policy ON public.restaurants
FOR SELECT TO authenticated
USING (
  is_super_admin()
  OR id = get_user_restaurant_id()
);
CREATE POLICY restaurants_super_admin_insert_policy ON public.restaurants
FOR INSERT TO authenticated
WITH CHECK (
  is_super_admin()
);
CREATE POLICY restaurants_admin_update_policy ON public.restaurants
FOR UPDATE TO authenticated
USING (
  is_super_admin()
  OR (
    id = get_user_restaurant_id()
    AND has_any_role(ARRAY['admin'])
  )
)
WITH CHECK (
  is_super_admin()
  OR (
    id = get_user_restaurant_id()
    AND has_any_role(ARRAY['admin'])
  )
);
-- ============================================================
-- tables/menu_categories/menu_items: reads remain tenant-scoped, writes admin only
-- ============================================================
DROP POLICY IF EXISTS tables_policy ON public.tables;
DROP POLICY IF EXISTS menu_categories_policy ON public.menu_categories;
DROP POLICY IF EXISTS menu_items_policy ON public.menu_items;
CREATE POLICY tables_select_policy ON public.tables
FOR SELECT TO authenticated
USING (
  is_super_admin()
  OR restaurant_id = get_user_restaurant_id()
);
CREATE POLICY tables_admin_write_policy ON public.tables
FOR INSERT TO authenticated
WITH CHECK (
  is_super_admin()
  OR (
    restaurant_id = get_user_restaurant_id()
    AND has_any_role(ARRAY['admin'])
  )
);
CREATE POLICY tables_admin_update_policy ON public.tables
FOR UPDATE TO authenticated
USING (
  is_super_admin()
  OR (
    restaurant_id = get_user_restaurant_id()
    AND has_any_role(ARRAY['admin'])
  )
)
WITH CHECK (
  is_super_admin()
  OR (
    restaurant_id = get_user_restaurant_id()
    AND has_any_role(ARRAY['admin'])
  )
);
CREATE POLICY tables_admin_delete_policy ON public.tables
FOR DELETE TO authenticated
USING (
  is_super_admin()
  OR (
    restaurant_id = get_user_restaurant_id()
    AND has_any_role(ARRAY['admin'])
  )
);
CREATE POLICY menu_categories_select_policy ON public.menu_categories
FOR SELECT TO authenticated
USING (
  is_super_admin()
  OR restaurant_id = get_user_restaurant_id()
);
CREATE POLICY menu_categories_admin_write_policy ON public.menu_categories
FOR INSERT TO authenticated
WITH CHECK (
  is_super_admin()
  OR (
    restaurant_id = get_user_restaurant_id()
    AND has_any_role(ARRAY['admin'])
  )
);
CREATE POLICY menu_categories_admin_update_policy ON public.menu_categories
FOR UPDATE TO authenticated
USING (
  is_super_admin()
  OR (
    restaurant_id = get_user_restaurant_id()
    AND has_any_role(ARRAY['admin'])
  )
)
WITH CHECK (
  is_super_admin()
  OR (
    restaurant_id = get_user_restaurant_id()
    AND has_any_role(ARRAY['admin'])
  )
);
CREATE POLICY menu_categories_admin_delete_policy ON public.menu_categories
FOR DELETE TO authenticated
USING (
  is_super_admin()
  OR (
    restaurant_id = get_user_restaurant_id()
    AND has_any_role(ARRAY['admin'])
  )
);
CREATE POLICY menu_items_select_policy ON public.menu_items
FOR SELECT TO authenticated
USING (
  is_super_admin()
  OR restaurant_id = get_user_restaurant_id()
);
CREATE POLICY menu_items_admin_write_policy ON public.menu_items
FOR INSERT TO authenticated
WITH CHECK (
  is_super_admin()
  OR (
    restaurant_id = get_user_restaurant_id()
    AND has_any_role(ARRAY['admin'])
  )
);
CREATE POLICY menu_items_admin_update_policy ON public.menu_items
FOR UPDATE TO authenticated
USING (
  is_super_admin()
  OR (
    restaurant_id = get_user_restaurant_id()
    AND has_any_role(ARRAY['admin'])
  )
)
WITH CHECK (
  is_super_admin()
  OR (
    restaurant_id = get_user_restaurant_id()
    AND has_any_role(ARRAY['admin'])
  )
);
CREATE POLICY menu_items_admin_delete_policy ON public.menu_items
FOR DELETE TO authenticated
USING (
  is_super_admin()
  OR (
    restaurant_id = get_user_restaurant_id()
    AND has_any_role(ARRAY['admin'])
  )
);
-- ============================================================
-- external_sales / delivery_settlements: authenticated read only
-- inserts reserved for service-side integrations
-- ============================================================
DROP POLICY IF EXISTS external_sales_insert ON public.external_sales;
DROP POLICY IF EXISTS delivery_settlements_insert ON public.delivery_settlements;
-- ============================================================
-- fingerprint: dormant feature closure
-- authenticated app access removed by default
-- ============================================================
DROP POLICY IF EXISTS fingerprint_templates_restaurant_policy ON public.fingerprint_templates;
