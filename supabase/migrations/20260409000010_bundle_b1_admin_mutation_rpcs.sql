-- ============================================================
-- Bundle B-1: admin mutation RPC boundaries for restaurants/tables/menu
-- 2026-04-09
-- Scope:
-- - move admin/super_admin writes to SECURITY DEFINER RPCs
-- - remove authenticated direct write policies
-- - add audit consistency with prior-state capture
-- ============================================================

-- ============================================================
-- Helper: active admin/super_admin actor for target restaurant
-- ============================================================
CREATE OR REPLACE FUNCTION public.require_admin_actor_for_restaurant(
  p_restaurant_id UUID
) RETURNS public.users AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ADMIN_MUTATION_FORBIDDEN';
  END IF;

  RETURN v_actor;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
-- ============================================================
-- Remove direct authenticated writes. Reads remain via Bundle A policies.
-- ============================================================
DROP POLICY IF EXISTS restaurants_super_admin_insert_policy ON public.restaurants;
DROP POLICY IF EXISTS restaurants_admin_update_policy ON public.restaurants;
DROP POLICY IF EXISTS tables_admin_write_policy ON public.tables;
DROP POLICY IF EXISTS tables_admin_update_policy ON public.tables;
DROP POLICY IF EXISTS tables_admin_delete_policy ON public.tables;
DROP POLICY IF EXISTS menu_categories_admin_write_policy ON public.menu_categories;
DROP POLICY IF EXISTS menu_categories_admin_update_policy ON public.menu_categories;
DROP POLICY IF EXISTS menu_categories_admin_delete_policy ON public.menu_categories;
DROP POLICY IF EXISTS menu_items_admin_write_policy ON public.menu_items;
DROP POLICY IF EXISTS menu_items_admin_update_policy ON public.menu_items;
DROP POLICY IF EXISTS menu_items_admin_delete_policy ON public.menu_items;
-- ============================================================
-- restaurants
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_create_restaurant(
  p_name TEXT,
  p_slug TEXT,
  p_operation_mode TEXT,
  p_address TEXT DEFAULT NULL,
  p_per_person_charge DECIMAL(12,2) DEFAULT NULL,
  p_brand_id UUID DEFAULT NULL,
  p_store_type TEXT DEFAULT 'direct'
) RETURNS public.restaurants AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_created public.restaurants%ROWTYPE;
BEGIN
  IF NULLIF(btrim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_NAME_REQUIRED';
  END IF;

  IF NULLIF(btrim(COALESCE(p_operation_mode, '')), '') IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_OPERATION_MODE_REQUIRED';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'RESTAURANT_CREATE_FORBIDDEN';
  END IF;

  INSERT INTO public.restaurants (
    name,
    address,
    slug,
    operation_mode,
    per_person_charge,
    brand_id,
    store_type,
    is_active,
    created_at
  )
  VALUES (
    btrim(p_name),
    NULLIF(btrim(COALESCE(p_address, '')), ''),
    NULLIF(btrim(COALESCE(p_slug, '')), ''),
    lower(p_operation_mode),
    p_per_person_charge,
    p_brand_id,
    COALESCE(p_store_type, 'direct'),
    TRUE,
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_restaurant',
    'restaurants',
    v_created.id,
    jsonb_build_object(
      'restaurant_id', v_created.id,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'name', v_created.name,
        'address', v_created.address,
        'slug', v_created.slug,
        'operation_mode', v_created.operation_mode,
        'per_person_charge', v_created.per_person_charge,
        'brand_id', v_created.brand_id,
        'store_type', v_created.store_type,
        'is_active', v_created.is_active
      )
    )
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
CREATE OR REPLACE FUNCTION public.admin_update_restaurant(
  p_restaurant_id UUID,
  p_name TEXT,
  p_slug TEXT,
  p_operation_mode TEXT,
  p_address TEXT DEFAULT NULL,
  p_per_person_charge DECIMAL(12,2) DEFAULT NULL,
  p_brand_id UUID DEFAULT NULL,
  p_store_type TEXT DEFAULT 'direct'
) RETURNS public.restaurants AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.restaurants%ROWTYPE;
  v_updated public.restaurants%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_slug TEXT := NULLIF(btrim(COALESCE(p_slug, '')), '');
  v_operation_mode TEXT := lower(COALESCE(p_operation_mode, ''));
  v_address TEXT := NULLIF(btrim(COALESCE(p_address, '')), '');
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_NAME_REQUIRED';
  END IF;

  IF v_operation_mode = '' THEN
    RAISE EXCEPTION 'RESTAURANT_OPERATION_MODE_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.restaurants
  WHERE id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTAURANT_NOT_FOUND';
  END IF;

  v_actor := public.require_admin_actor_for_restaurant(v_existing.id);

  IF v_name IS DISTINCT FROM v_existing.name THEN
    v_changed_fields := array_append(v_changed_fields, 'name');
    v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
    v_new_values := v_new_values || jsonb_build_object('name', v_name);
  END IF;

  IF v_address IS DISTINCT FROM v_existing.address THEN
    v_changed_fields := array_append(v_changed_fields, 'address');
    v_old_values := v_old_values || jsonb_build_object('address', v_existing.address);
    v_new_values := v_new_values || jsonb_build_object('address', v_address);
  END IF;

  IF v_slug IS DISTINCT FROM v_existing.slug THEN
    v_changed_fields := array_append(v_changed_fields, 'slug');
    v_old_values := v_old_values || jsonb_build_object('slug', v_existing.slug);
    v_new_values := v_new_values || jsonb_build_object('slug', v_slug);
  END IF;

  IF v_operation_mode IS DISTINCT FROM v_existing.operation_mode THEN
    v_changed_fields := array_append(v_changed_fields, 'operation_mode');
    v_old_values := v_old_values || jsonb_build_object('operation_mode', v_existing.operation_mode);
    v_new_values := v_new_values || jsonb_build_object('operation_mode', v_operation_mode);
  END IF;

  IF p_per_person_charge IS DISTINCT FROM v_existing.per_person_charge THEN
    v_changed_fields := array_append(v_changed_fields, 'per_person_charge');
    v_old_values := v_old_values || jsonb_build_object('per_person_charge', v_existing.per_person_charge);
    v_new_values := v_new_values || jsonb_build_object('per_person_charge', p_per_person_charge);
  END IF;

  IF p_brand_id IS DISTINCT FROM v_existing.brand_id THEN
    v_changed_fields := array_append(v_changed_fields, 'brand_id');
    v_old_values := v_old_values || jsonb_build_object('brand_id', v_existing.brand_id);
    v_new_values := v_new_values || jsonb_build_object('brand_id', p_brand_id);
  END IF;

  IF COALESCE(p_store_type, 'direct') IS DISTINCT FROM v_existing.store_type THEN
    v_changed_fields := array_append(v_changed_fields, 'store_type');
    v_old_values := v_old_values || jsonb_build_object('store_type', v_existing.store_type);
    v_new_values := v_new_values || jsonb_build_object('store_type', COALESCE(p_store_type, 'direct'));
  END IF;

  UPDATE public.restaurants
  SET name = v_name,
      address = v_address,
      slug = v_slug,
      operation_mode = v_operation_mode,
      per_person_charge = p_per_person_charge,
      brand_id = p_brand_id,
      store_type = COALESCE(p_store_type, 'direct')
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_restaurant',
      'restaurants',
      v_updated.id,
      jsonb_build_object(
        'restaurant_id', v_updated.id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
CREATE OR REPLACE FUNCTION public.admin_deactivate_restaurant(
  p_restaurant_id UUID
) RETURNS public.restaurants AS $$
DECLARE
  v_existing public.restaurants%ROWTYPE;
  v_updated public.restaurants%ROWTYPE;
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.restaurants
  WHERE id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTAURANT_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.id);

  UPDATE public.restaurants
  SET is_active = FALSE
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_deactivate_restaurant',
    'restaurants',
    v_updated.id,
    jsonb_build_object(
      'restaurant_id', v_updated.id,
      'changed_fields', jsonb_build_array('is_active'),
      'old_values', jsonb_build_object('is_active', v_existing.is_active),
      'new_values', jsonb_build_object('is_active', v_updated.is_active),
      'updated_at_utc', now()
    )
  );

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
CREATE OR REPLACE FUNCTION public.admin_update_restaurant_settings(
  p_restaurant_id UUID,
  p_name TEXT,
  p_operation_mode TEXT,
  p_address TEXT DEFAULT NULL,
  p_per_person_charge DECIMAL(12,2) DEFAULT NULL
) RETURNS public.restaurants AS $$
DECLARE
  v_existing public.restaurants%ROWTYPE;
  v_updated public.restaurants%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_operation_mode TEXT := lower(COALESCE(p_operation_mode, ''));
  v_address TEXT := NULLIF(btrim(COALESCE(p_address, '')), '');
BEGIN
  IF p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_NAME_REQUIRED';
  END IF;

  IF v_operation_mode = '' THEN
    RAISE EXCEPTION 'RESTAURANT_OPERATION_MODE_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.restaurants
  WHERE id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTAURANT_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.id);

  IF v_name IS DISTINCT FROM v_existing.name THEN
    v_changed_fields := array_append(v_changed_fields, 'name');
    v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
    v_new_values := v_new_values || jsonb_build_object('name', v_name);
  END IF;

  IF v_address IS DISTINCT FROM v_existing.address THEN
    v_changed_fields := array_append(v_changed_fields, 'address');
    v_old_values := v_old_values || jsonb_build_object('address', v_existing.address);
    v_new_values := v_new_values || jsonb_build_object('address', v_address);
  END IF;

  IF v_operation_mode IS DISTINCT FROM v_existing.operation_mode THEN
    v_changed_fields := array_append(v_changed_fields, 'operation_mode');
    v_old_values := v_old_values || jsonb_build_object('operation_mode', v_existing.operation_mode);
    v_new_values := v_new_values || jsonb_build_object('operation_mode', v_operation_mode);
  END IF;

  IF p_per_person_charge IS DISTINCT FROM v_existing.per_person_charge THEN
    v_changed_fields := array_append(v_changed_fields, 'per_person_charge');
    v_old_values := v_old_values || jsonb_build_object('per_person_charge', v_existing.per_person_charge);
    v_new_values := v_new_values || jsonb_build_object('per_person_charge', p_per_person_charge);
  END IF;

  UPDATE public.restaurants
  SET name = v_name,
      address = v_address,
      operation_mode = v_operation_mode,
      per_person_charge = p_per_person_charge
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_restaurant_settings',
      'restaurants',
      v_updated.id,
      jsonb_build_object(
        'restaurant_id', v_updated.id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
-- ============================================================
-- tables
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_create_table(
  p_restaurant_id UUID,
  p_table_number TEXT,
  p_seat_count INT
) RETURNS public.tables AS $$
DECLARE
  v_created public.tables%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_restaurant_id);

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
    p_restaurant_id,
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
      'restaurant_id', v_created.restaurant_id,
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
CREATE OR REPLACE FUNCTION public.admin_update_table(
  p_table_id UUID,
  p_table_number TEXT DEFAULT NULL,
  p_seat_count INT DEFAULT NULL,
  p_status TEXT DEFAULT NULL
) RETURNS public.tables AS $$
DECLARE
  v_existing public.tables%ROWTYPE;
  v_updated public.tables%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_table_number TEXT := NULLIF(btrim(COALESCE(p_table_number, '')), '');
BEGIN
  IF p_table_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.tables
  WHERE id = p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

  IF p_table_number IS NOT NULL THEN
    IF v_table_number IS NULL THEN
      RAISE EXCEPTION 'TABLE_NUMBER_REQUIRED';
    END IF;
    IF v_table_number IS DISTINCT FROM v_existing.table_number THEN
      v_changed_fields := array_append(v_changed_fields, 'table_number');
      v_old_values := v_old_values || jsonb_build_object('table_number', v_existing.table_number);
      v_new_values := v_new_values || jsonb_build_object('table_number', v_table_number);
    END IF;
  ELSE
    v_table_number := v_existing.table_number;
  END IF;

  IF p_seat_count IS NOT NULL AND p_seat_count IS DISTINCT FROM v_existing.seat_count THEN
    v_changed_fields := array_append(v_changed_fields, 'seat_count');
    v_old_values := v_old_values || jsonb_build_object('seat_count', v_existing.seat_count);
    v_new_values := v_new_values || jsonb_build_object('seat_count', p_seat_count);
  END IF;

  IF p_status IS NOT NULL AND p_status IS DISTINCT FROM v_existing.status THEN
    v_changed_fields := array_append(v_changed_fields, 'status');
    v_old_values := v_old_values || jsonb_build_object('status', v_existing.status);
    v_new_values := v_new_values || jsonb_build_object('status', p_status);
  END IF;

  UPDATE public.tables
  SET table_number = v_table_number,
      seat_count = COALESCE(p_seat_count, v_existing.seat_count),
      status = COALESCE(p_status, v_existing.status),
      updated_at = now()
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_table',
      'tables',
      v_updated.id,
      jsonb_build_object(
        'restaurant_id', v_updated.restaurant_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
CREATE OR REPLACE FUNCTION public.admin_delete_table(
  p_table_id UUID
) RETURNS public.tables AS $$
DECLARE
  v_existing public.tables%ROWTYPE;
BEGIN
  IF p_table_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.tables
  WHERE id = p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

  DELETE FROM public.tables
  WHERE id = v_existing.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_table',
    'tables',
    v_existing.id,
    jsonb_build_object(
      'restaurant_id', v_existing.restaurant_id,
      'deleted_at_utc', now(),
      'old_values', jsonb_build_object(
        'table_number', v_existing.table_number,
        'seat_count', v_existing.seat_count,
        'status', v_existing.status
      )
    )
  );

  RETURN v_existing;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
-- ============================================================
-- menu_categories
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_create_menu_category(
  p_restaurant_id UUID,
  p_name TEXT,
  p_sort_order INT DEFAULT 0
) RETURNS public.menu_categories AS $$
DECLARE
  v_created public.menu_categories%ROWTYPE;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_restaurant_id);

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
    p_restaurant_id,
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
      'restaurant_id', v_created.restaurant_id,
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
CREATE OR REPLACE FUNCTION public.admin_update_menu_category(
  p_category_id UUID,
  p_name TEXT DEFAULT NULL,
  p_sort_order INT DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT NULL
) RETURNS public.menu_categories AS $$
DECLARE
  v_existing public.menu_categories%ROWTYPE;
  v_updated public.menu_categories%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
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

  IF p_name IS NOT NULL THEN
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'MENU_CATEGORY_NAME_REQUIRED';
    END IF;
    IF v_name IS DISTINCT FROM v_existing.name THEN
      v_changed_fields := array_append(v_changed_fields, 'name');
      v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
      v_new_values := v_new_values || jsonb_build_object('name', v_name);
    END IF;
  ELSE
    v_name := v_existing.name;
  END IF;

  IF p_sort_order IS NOT NULL AND p_sort_order IS DISTINCT FROM v_existing.sort_order THEN
    v_changed_fields := array_append(v_changed_fields, 'sort_order');
    v_old_values := v_old_values || jsonb_build_object('sort_order', v_existing.sort_order);
    v_new_values := v_new_values || jsonb_build_object('sort_order', p_sort_order);
  END IF;

  IF p_is_active IS NOT NULL AND p_is_active IS DISTINCT FROM v_existing.is_active THEN
    v_changed_fields := array_append(v_changed_fields, 'is_active');
    v_old_values := v_old_values || jsonb_build_object('is_active', v_existing.is_active);
    v_new_values := v_new_values || jsonb_build_object('is_active', p_is_active);
  END IF;

  UPDATE public.menu_categories
  SET name = v_name,
      sort_order = COALESCE(p_sort_order, v_existing.sort_order),
      is_active = COALESCE(p_is_active, v_existing.is_active)
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_menu_category',
      'menu_categories',
      v_updated.id,
      jsonb_build_object(
        'restaurant_id', v_updated.restaurant_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
CREATE OR REPLACE FUNCTION public.admin_delete_menu_category(
  p_category_id UUID
) RETURNS public.menu_categories AS $$
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

  DELETE FROM public.menu_categories
  WHERE id = v_existing.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_menu_category',
    'menu_categories',
    v_existing.id,
    jsonb_build_object(
      'restaurant_id', v_existing.restaurant_id,
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
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
-- ============================================================
-- menu_items
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_create_menu_item(
  p_restaurant_id UUID,
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
  PERFORM public.require_admin_actor_for_restaurant(p_restaurant_id);

  IF NULLIF(btrim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_NAME_REQUIRED';
  END IF;

  IF p_category_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_categories
    WHERE id = p_category_id
      AND restaurant_id = p_restaurant_id
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
    p_restaurant_id,
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
      'restaurant_id', v_created.restaurant_id,
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
CREATE OR REPLACE FUNCTION public.admin_update_menu_item(
  p_item_id UUID,
  p_category_id UUID DEFAULT NULL,
  p_name TEXT DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_price DECIMAL(12,2) DEFAULT NULL,
  p_is_available BOOLEAN DEFAULT NULL,
  p_is_visible_public BOOLEAN DEFAULT NULL,
  p_sort_order INT DEFAULT NULL
) RETURNS public.menu_items AS $$
DECLARE
  v_existing public.menu_items%ROWTYPE;
  v_updated public.menu_items%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_name TEXT := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_description TEXT := NULLIF(btrim(COALESCE(p_description, '')), '');
BEGIN
  IF p_item_id IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_items
  WHERE id = p_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

  IF p_category_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_categories
    WHERE id = p_category_id
      AND restaurant_id = v_existing.restaurant_id
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  IF p_name IS NOT NULL THEN
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'MENU_ITEM_NAME_REQUIRED';
    END IF;
    IF v_name IS DISTINCT FROM v_existing.name THEN
      v_changed_fields := array_append(v_changed_fields, 'name');
      v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
      v_new_values := v_new_values || jsonb_build_object('name', v_name);
    END IF;
  ELSE
    v_name := v_existing.name;
  END IF;

  IF p_category_id IS NOT NULL AND p_category_id IS DISTINCT FROM v_existing.category_id THEN
    v_changed_fields := array_append(v_changed_fields, 'category_id');
    v_old_values := v_old_values || jsonb_build_object('category_id', v_existing.category_id);
    v_new_values := v_new_values || jsonb_build_object('category_id', p_category_id);
  END IF;

  IF p_description IS NOT NULL AND v_description IS DISTINCT FROM v_existing.description THEN
    v_changed_fields := array_append(v_changed_fields, 'description');
    v_old_values := v_old_values || jsonb_build_object('description', v_existing.description);
    v_new_values := v_new_values || jsonb_build_object('description', v_description);
  END IF;

  IF p_price IS NOT NULL AND p_price IS DISTINCT FROM v_existing.price THEN
    v_changed_fields := array_append(v_changed_fields, 'price');
    v_old_values := v_old_values || jsonb_build_object('price', v_existing.price);
    v_new_values := v_new_values || jsonb_build_object('price', p_price);
  END IF;

  IF p_is_available IS NOT NULL AND p_is_available IS DISTINCT FROM v_existing.is_available THEN
    v_changed_fields := array_append(v_changed_fields, 'is_available');
    v_old_values := v_old_values || jsonb_build_object('is_available', v_existing.is_available);
    v_new_values := v_new_values || jsonb_build_object('is_available', p_is_available);
  END IF;

  IF p_is_visible_public IS NOT NULL AND p_is_visible_public IS DISTINCT FROM v_existing.is_visible_public THEN
    v_changed_fields := array_append(v_changed_fields, 'is_visible_public');
    v_old_values := v_old_values || jsonb_build_object('is_visible_public', v_existing.is_visible_public);
    v_new_values := v_new_values || jsonb_build_object('is_visible_public', p_is_visible_public);
  END IF;

  IF p_sort_order IS NOT NULL AND p_sort_order IS DISTINCT FROM v_existing.sort_order THEN
    v_changed_fields := array_append(v_changed_fields, 'sort_order');
    v_old_values := v_old_values || jsonb_build_object('sort_order', v_existing.sort_order);
    v_new_values := v_new_values || jsonb_build_object('sort_order', p_sort_order);
  END IF;

  UPDATE public.menu_items
  SET category_id = COALESCE(p_category_id, v_existing.category_id),
      name = v_name,
      description = CASE
        WHEN p_description IS NULL THEN v_existing.description
        ELSE v_description
      END,
      price = COALESCE(p_price, v_existing.price),
      is_available = COALESCE(p_is_available, v_existing.is_available),
      is_visible_public = COALESCE(p_is_visible_public, v_existing.is_visible_public),
      sort_order = COALESCE(p_sort_order, v_existing.sort_order),
      updated_at = now()
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_menu_item',
      'menu_items',
      v_updated.id,
      jsonb_build_object(
        'restaurant_id', v_updated.restaurant_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
CREATE OR REPLACE FUNCTION public.admin_delete_menu_item(
  p_item_id UUID
) RETURNS public.menu_items AS $$
DECLARE
  v_existing public.menu_items%ROWTYPE;
BEGIN
  IF p_item_id IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_items
  WHERE id = p_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

  DELETE FROM public.menu_items
  WHERE id = v_existing.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_menu_item',
    'menu_items',
    v_existing.id,
    jsonb_build_object(
      'restaurant_id', v_existing.restaurant_id,
      'deleted_at_utc', now(),
      'old_values', jsonb_build_object(
        'category_id', v_existing.category_id,
        'name', v_existing.name,
        'description', v_existing.description,
        'price', v_existing.price,
        'is_available', v_existing.is_available,
        'is_visible_public', v_existing.is_visible_public,
        'sort_order', v_existing.sort_order
      )
    )
  );

  RETURN v_existing;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
