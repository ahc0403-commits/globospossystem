BEGIN;

DROP FUNCTION IF EXISTS public.set_payroll_pin(uuid, text);
DROP FUNCTION IF EXISTS public.clear_payroll_pin(uuid);

CREATE FUNCTION public.set_payroll_pin(
  p_store_id uuid,
  p_payroll_pin text
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_settings_id uuid;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;

  IF p_payroll_pin IS NULL
     OR p_payroll_pin !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'PAYROLL_PIN_HASH_INVALID';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  INSERT INTO public.restaurant_settings (
    restaurant_id,
    payroll_pin,
    updated_at
  )
  VALUES (
    p_store_id,
    p_payroll_pin,
    now()
  )
  ON CONFLICT (restaurant_id)
  DO UPDATE SET
    payroll_pin = EXCLUDED.payroll_pin,
    updated_at = now()
  RETURNING id INTO v_settings_id;

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  )
  VALUES (
    auth.uid(),
    'set_payroll_pin',
    'restaurant_settings',
    v_settings_id,
    jsonb_build_object('store_id', p_store_id, 'updated_at_utc', now())
  );

  RETURN true;
END;
$$;

CREATE FUNCTION public.clear_payroll_pin(
  p_store_id uuid
) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_settings_id uuid;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_ID_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  INSERT INTO public.restaurant_settings (
    restaurant_id,
    payroll_pin,
    updated_at
  )
  VALUES (
    p_store_id,
    NULL,
    now()
  )
  ON CONFLICT (restaurant_id)
  DO UPDATE SET
    payroll_pin = NULL,
    updated_at = now()
  RETURNING id INTO v_settings_id;

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  )
  VALUES (
    auth.uid(),
    'clear_payroll_pin',
    'restaurant_settings',
    v_settings_id,
    jsonb_build_object('store_id', p_store_id, 'updated_at_utc', now())
  );

  RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.set_payroll_pin(uuid, text)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.clear_payroll_pin(uuid)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_payroll_pin(uuid, text)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.clear_payroll_pin(uuid)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.set_payroll_pin(uuid, text) IS
  'Stores the client-generated payroll PIN hash for an admin-accessible store without returning the settings row.';
COMMENT ON FUNCTION public.clear_payroll_pin(uuid) IS
  'Clears the payroll PIN for an admin-accessible store without returning the settings row.';

COMMIT;
