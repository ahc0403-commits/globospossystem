BEGIN;

CREATE OR REPLACE FUNCTION public.has_payroll_pin(
  p_store_id uuid
) RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  RETURN EXISTS (
    SELECT 1
    FROM public.restaurant_settings settings
    WHERE settings.restaurant_id = p_store_id
      AND NULLIF(btrim(settings.payroll_pin), '') IS NOT NULL
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.verify_payroll_pin(
  p_store_id uuid,
  p_payroll_pin text
) RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  IF p_payroll_pin IS NULL
     OR p_payroll_pin !~ '^[0-9a-f]{64}$' THEN
    RETURN false;
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  RETURN EXISTS (
    SELECT 1
    FROM public.restaurant_settings settings
    WHERE settings.restaurant_id = p_store_id
      AND settings.payroll_pin = p_payroll_pin
  );
END;
$$;

REVOKE ALL ON FUNCTION public.has_payroll_pin(uuid)
  FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.verify_payroll_pin(uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_payroll_pin(uuid)
  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.verify_payroll_pin(uuid, text)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.has_payroll_pin(uuid) IS
  'Returns payroll PIN presence for an admin-accessible store without exposing the stored hash.';
COMMENT ON FUNCTION public.verify_payroll_pin(uuid, text) IS
  'Checks a client-generated payroll PIN hash for an admin-accessible store without exposing the stored hash.';

-- production-gate: self-verifying
DO $$
BEGIN
  IF to_regprocedure('public.has_payroll_pin(uuid)') IS NULL
     OR to_regprocedure('public.verify_payroll_pin(uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'PAYROLL_PIN_STATUS_RPC_MISSING';
  END IF;

  IF has_function_privilege('anon', 'public.has_payroll_pin(uuid)', 'EXECUTE')
     OR has_function_privilege(
       'anon',
       'public.verify_payroll_pin(uuid,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PAYROLL_PIN_STATUS_RPC_ANON_EXECUTE_PRESENT';
  END IF;

  IF NOT has_function_privilege(
       'authenticated',
       'public.has_payroll_pin(uuid)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.verify_payroll_pin(uuid,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PAYROLL_PIN_STATUS_RPC_AUTH_EXECUTE_MISSING';
  END IF;
END;
$$;

COMMIT;
