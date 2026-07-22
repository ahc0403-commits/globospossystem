-- Add the missing bank name to employee payment profiles.
ALTER TABLE public.store_employees
  ADD COLUMN IF NOT EXISTS bank_name text;

CREATE OR REPLACE FUNCTION public.store_employee_profile_outbox_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND (
    NEW.phone IS DISTINCT FROM OLD.phone
    OR NEW.bank_name IS DISTINCT FROM OLD.bank_name
    OR NEW.bank_account_number IS DISTINCT FROM OLD.bank_account_number
    OR NEW.bank_account_holder IS DISTINCT FROM OLD.bank_account_holder
    OR NEW.is_active IS DISTINCT FROM OLD.is_active
  ) THEN
    NEW.payment_profile_version := nextval('public.store_employee_payment_profile_version_seq');
  END IF;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.create_store_employee(
  p_store_id uuid,
  p_full_name text,
  p_employment_role text,
  p_phone text,
  p_bank_account_number text,
  p_bank_account_holder text,
  p_bank_name text
) RETURNS public.store_employees
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_short_code text;
  v_number bigint;
  v_employee public.store_employees%ROWTYPE;
BEGIN
  v_actor := public.require_workforce_manager(p_store_id);
  SELECT short_code INTO v_short_code
  FROM public.restaurants
  WHERE id = p_store_id AND is_active = true;
  IF v_short_code IS NULL THEN
    RAISE EXCEPTION 'STORE_SHORT_CODE_REQUIRED';
  END IF;
  IF p_employment_role NOT IN ('part_timer', 'full_time', 'manager') THEN
    RAISE EXCEPTION 'EMPLOYMENT_ROLE_INVALID';
  END IF;
  IF NULLIF(btrim(COALESCE(p_full_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_NAME_REQUIRED';
  END IF;

  INSERT INTO public.store_employee_number_sequences(store_id, next_value)
  VALUES (p_store_id, 2)
  ON CONFLICT (store_id) DO UPDATE SET
    next_value = public.store_employee_number_sequences.next_value + 1,
    updated_at = now()
  RETURNING next_value - 1 INTO v_number;

  INSERT INTO public.store_employees(
    store_id, employee_number, full_name, employment_role, phone,
    bank_name, bank_account_number, bank_account_holder, created_by_user_id
  ) VALUES (
    p_store_id, upper(v_short_code) || v_number::text, btrim(p_full_name),
    p_employment_role, NULLIF(btrim(COALESCE(p_phone, '')), ''),
    NULLIF(btrim(COALESCE(p_bank_name, '')), ''),
    NULLIF(btrim(COALESCE(p_bank_account_number, '')), ''),
    NULLIF(btrim(COALESCE(p_bank_account_holder, '')), ''), v_actor.id
  ) RETURNING * INTO v_employee;

  RETURN v_employee;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_store_employee(
  p_store_id uuid,
  p_employee_id uuid,
  p_full_name text,
  p_employment_role text,
  p_phone text,
  p_bank_account_number text,
  p_bank_account_holder text,
  p_bank_name text
) RETURNS public.store_employees
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_employee public.store_employees%ROWTYPE;
BEGIN
  PERFORM public.require_workforce_manager(p_store_id);
  IF p_employment_role NOT IN ('part_timer', 'full_time', 'manager') THEN
    RAISE EXCEPTION 'EMPLOYMENT_ROLE_INVALID';
  END IF;
  IF NULLIF(btrim(COALESCE(p_full_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_NAME_REQUIRED';
  END IF;
  UPDATE public.store_employees SET
    full_name = btrim(p_full_name),
    employment_role = p_employment_role,
    phone = NULLIF(btrim(COALESCE(p_phone, '')), ''),
    bank_name = NULLIF(btrim(COALESCE(p_bank_name, '')), ''),
    bank_account_number = NULLIF(btrim(COALESCE(p_bank_account_number, '')), ''),
    bank_account_holder = NULLIF(btrim(COALESCE(p_bank_account_holder, '')), '')
  WHERE id = p_employee_id AND store_id = p_store_id
  RETURNING * INTO v_employee;
  IF NOT FOUND THEN RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND'; END IF;
  RETURN v_employee;
END;
$$;

DROP FUNCTION public.office_list_employee_payment_profiles(bigint, integer);
CREATE FUNCTION public.office_list_employee_payment_profiles(
  p_after_version bigint DEFAULT 0,
  p_limit integer DEFAULT 500
) RETURNS TABLE (
  pos_employee_id uuid,
  pos_store_id uuid,
  profile_version bigint,
  phone text,
  bank_name text,
  bank_account_number text,
  bank_account_holder text,
  is_active boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  IF COALESCE(auth.jwt()->>'role', '') <> 'service_role' THEN
    RAISE EXCEPTION 'OFFICE_PAYMENT_PROFILE_SYNC_FORBIDDEN';
  END IF;
  IF p_after_version < 0 OR p_limit NOT BETWEEN 1 AND 1000 THEN
    RAISE EXCEPTION 'OFFICE_PAYMENT_PROFILE_SYNC_INPUT_INVALID';
  END IF;
  RETURN QUERY
  SELECT e.id, e.store_id, e.payment_profile_version, e.phone,
    e.bank_name, e.bank_account_number, e.bank_account_holder, e.is_active
  FROM public.store_employees e
  WHERE e.payment_profile_version > p_after_version
  ORDER BY e.payment_profile_version, e.id
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.create_store_employee(
  uuid, text, text, text, text, text, text
) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.update_store_employee(
  uuid, uuid, text, text, text, text, text, text
) FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.office_list_employee_payment_profiles(bigint, integer)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.create_store_employee(
  uuid, text, text, text, text, text, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_store_employee(
  uuid, uuid, text, text, text, text, text, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.office_list_employee_payment_profiles(bigint, integer)
  TO service_role;

COMMENT ON FUNCTION public.office_list_employee_payment_profiles(bigint, integer) IS
  'Service-role-only, versioned employee payment profile export including bank name.';
