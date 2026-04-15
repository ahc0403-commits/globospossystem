BEGIN;

DROP FUNCTION IF EXISTS public.complete_onboarding_account_setup(uuid, text, text);
DROP FUNCTION IF EXISTS public.admin_update_staff_account(uuid, uuid, text, boolean, text[]);

CREATE OR REPLACE FUNCTION public.complete_onboarding_account_setup(
  p_store_id uuid,
  p_full_name text,
  p_role text
) RETURNS public.users AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_updated public.users%ROWTYPE;
  v_full_name text := NULLIF(btrim(COALESCE(p_full_name, '')), '');
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'ONBOARDING_STORE_REQUIRED';
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
  SET restaurant_id = p_store_id,
      primary_store_id = p_store_id,
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
      'store_id', p_store_id,
      'new_role', p_role
    )
  );

  PERFORM public.refresh_user_claims(v_updated.auth_id);

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.admin_update_staff_account(
  p_user_id uuid,
  p_store_id uuid,
  p_full_name text DEFAULT NULL,
  p_is_active boolean DEFAULT NULL,
  p_extra_permissions text[] DEFAULT NULL
)
RETURNS public.users AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_target public.users%ROWTYPE;
  v_updated public.users%ROWTYPE;
  v_target_brand_id uuid;
  v_full_name text := NULLIF(btrim(COALESCE(p_full_name, '')), '');
  v_changed_fields text[] := ARRAY[]::text[];
  v_old_values jsonb := '{}'::jsonb;
  v_new_values jsonb := '{}'::jsonb;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  IF p_user_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_INVALID';
  END IF;

  SELECT brand_id
  INTO v_target_brand_id
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_INVALID';
  END IF;

  IF v_actor.role IN ('admin', 'store_admin')
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  IF v_actor.role = 'brand_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_brands(auth.uid()) b(brand_id)
       WHERE b.brand_id = v_target_brand_id
     ) THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_target
  FROM public.users
  WHERE id = p_user_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_NOT_FOUND';
  END IF;

  IF v_actor.role IN ('admin', 'store_admin')
     AND v_target.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin', 'photo_objet_master') THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  IF v_actor.role = 'brand_admin'
     AND v_target.role IN ('brand_admin', 'super_admin', 'photo_objet_master') THEN
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
     AND COALESCE(p_extra_permissions, ARRAY[]::text[]) IS DISTINCT FROM COALESCE(v_target.extra_permissions, ARRAY[]::text[]) THEN
    v_changed_fields := array_append(v_changed_fields, 'extra_permissions');
    v_old_values := v_old_values || jsonb_build_object('extra_permissions', COALESCE(v_target.extra_permissions, ARRAY[]::text[]));
    v_new_values := v_new_values || jsonb_build_object('extra_permissions', COALESCE(p_extra_permissions, ARRAY[]::text[]));
  END IF;

  UPDATE public.users
  SET full_name = v_full_name,
      is_active = COALESCE(p_is_active, v_target.is_active),
      extra_permissions = CASE
        WHEN p_extra_permissions IS NULL THEN v_target.extra_permissions
        ELSE COALESCE(p_extra_permissions, ARRAY[]::text[])
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
        'store_id', v_updated.restaurant_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values
      )
    );

    PERFORM public.refresh_user_claims(v_target.auth_id);
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

COMMIT;
