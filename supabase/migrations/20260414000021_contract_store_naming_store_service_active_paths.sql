-- ============================================================
-- Contract phase: rename active store admin mutation RPC inputs to store naming
-- 2026-04-14
-- Scope:
-- - admin_update_restaurant
-- - admin_update_restaurant_settings
-- - admin_deactivate_restaurant
-- Notes:
-- - canonical RPC names stay unchanged during coexistence
-- - physical schema still uses restaurants / restaurant_id
-- ============================================================

DROP FUNCTION IF EXISTS public.admin_update_restaurant(uuid, text, text, text, text, numeric, uuid, text);
DROP FUNCTION IF EXISTS public.admin_deactivate_restaurant(uuid);
DROP FUNCTION IF EXISTS public.admin_update_restaurant_settings(uuid, text, text, text, numeric);

CREATE OR REPLACE FUNCTION public.admin_update_restaurant(
  p_store_id UUID,
  p_name TEXT,
  p_slug TEXT,
  p_operation_mode TEXT,
  p_address TEXT DEFAULT NULL,
  p_per_person_charge DECIMAL(12,2) DEFAULT NULL,
  p_brand_id UUID DEFAULT NULL,
  p_store_type TEXT DEFAULT 'direct'
) RETURNS public.restaurants AS $$
DECLARE
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
  IF p_store_id IS NULL THEN
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
  WHERE id = p_store_id
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
        'store_id', v_updated.id,
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
  p_store_id UUID
) RETURNS public.restaurants AS $$
DECLARE
  v_existing public.restaurants%ROWTYPE;
  v_updated public.restaurants%ROWTYPE;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.restaurants
  WHERE id = p_store_id
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
      'store_id', v_updated.id,
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
  p_store_id UUID,
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
  IF p_store_id IS NULL THEN
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
  WHERE id = p_store_id
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
        'store_id', v_updated.id,
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
