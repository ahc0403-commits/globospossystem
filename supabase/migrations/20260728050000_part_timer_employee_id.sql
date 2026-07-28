BEGIN;

-- Part-timer IDs are human-readable: <STORE_CODE>_<GIVEN_NAME>.
-- Existing numeric IDs remain valid so historical attendance records do not
-- need to be rewritten.
ALTER TABLE public.store_employees
  DROP CONSTRAINT IF EXISTS store_employees_number_check;
ALTER TABLE public.store_employees
  ADD CONSTRAINT store_employees_number_check CHECK (
    employee_number ~ '^[A-Z0-9]{2,6}[1-9][0-9]*$'
    OR employee_number ~ '^[A-Z0-9]{2,6}_[A-Za-z][A-Za-z0-9_]{0,39}$'
  );

CREATE OR REPLACE FUNCTION public.part_timer_employee_name_token(
  p_full_name text
) RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog
AS $$
DECLARE
  v_last_name text;
  v_ascii text;
BEGIN
  v_last_name := regexp_replace(
    btrim(COALESCE(p_full_name, '')),
    '^.*[[:space:]]+',
    ''
  );
  v_ascii := lower(v_last_name);
  v_ascii := regexp_replace(v_ascii, '[àáạảãâầấậẩẫăằắặẳẵ]', 'a', 'g');
  v_ascii := regexp_replace(v_ascii, '[èéẹẻẽêềếệểễ]', 'e', 'g');
  v_ascii := regexp_replace(v_ascii, '[ìíịỉĩ]', 'i', 'g');
  v_ascii := regexp_replace(v_ascii, '[òóọỏõôồốộổỗơờớợởỡ]', 'o', 'g');
  v_ascii := regexp_replace(v_ascii, '[ùúụủũưừứựửữ]', 'u', 'g');
  v_ascii := regexp_replace(v_ascii, '[ỳýỵỷỹ]', 'y', 'g');
  v_ascii := replace(v_ascii, 'đ', 'd');
  v_ascii := regexp_replace(v_ascii, '[^a-z0-9]', '', 'g');
  IF v_ascii = '' THEN
    RAISE EXCEPTION 'EMPLOYEE_NAME_ID_INVALID';
  END IF;
  RETURN upper(substr(v_ascii, 1, 1)) || lower(substr(v_ascii, 2));
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
  v_employee_number text;
  v_conflicting_employee_id uuid;
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

  IF p_employment_role = 'part_timer' THEN
    v_employee_number := left(upper(v_short_code), 2)
      || '_'
      || public.part_timer_employee_name_token(p_full_name);

    -- Serialize identical IDs so concurrent requests receive the same clear
    -- business error instead of a raw unique-index violation.
    PERFORM pg_advisory_xact_lock(
      hashtextextended(lower(v_employee_number), 0)
    );
    SELECT id INTO v_conflicting_employee_id
    FROM public.store_employees
    WHERE upper(employee_number) = upper(v_employee_number)
    ORDER BY created_at
    LIMIT 1;
    IF v_conflicting_employee_id IS NOT NULL THEN
      RAISE EXCEPTION 'EMPLOYEE_ID_DUPLICATE'
        USING DETAIL = v_conflicting_employee_id::text,
              HINT = 'Edit the existing employee instead of creating another account.';
    END IF;
  ELSE
    -- Full-time and manager IDs keep the existing monotonic rule.
    INSERT INTO public.store_employee_number_sequences(store_id, next_value)
    VALUES (p_store_id, 2)
    ON CONFLICT (store_id) DO UPDATE SET
      next_value = public.store_employee_number_sequences.next_value + 1,
      updated_at = now()
    RETURNING next_value - 1 INTO v_number;
    v_employee_number := upper(v_short_code) || v_number::text;
  END IF;

  INSERT INTO public.store_employees(
    store_id, employee_number, full_name, employment_role, phone,
    bank_name, bank_account_number, bank_account_holder, created_by_user_id
  ) VALUES (
    p_store_id, v_employee_number, btrim(p_full_name),
    p_employment_role, NULLIF(btrim(COALESCE(p_phone, '')), ''),
    NULLIF(btrim(COALESCE(p_bank_name, '')), ''),
    NULLIF(btrim(COALESCE(p_bank_account_number, '')), ''),
    NULLIF(btrim(COALESCE(p_bank_account_holder, '')), ''), v_actor.id
  ) RETURNING * INTO v_employee;

  RETURN v_employee;
END;
$$;

-- Treat inactive historical rows as duplicates too. Re-activation/editing is
-- safer than creating a second payroll identity for the same person.
CREATE OR REPLACE FUNCTION public.guard_duplicate_store_employee()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_phone_key text;
  v_duplicate_id uuid;
BEGIN
  v_phone_key := regexp_replace(COALESCE(NEW.phone, ''), '[^0-9]', '', 'g');
  IF v_phone_key LIKE '840%' THEN
    v_phone_key := substr(v_phone_key, 3);
  ELSIF v_phone_key LIKE '84%' AND length(v_phone_key) = 11 THEN
    v_phone_key := '0' || substr(v_phone_key, 3);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(
    NEW.store_id::text || '|'
      || lower(regexp_replace(btrim(COALESCE(NEW.full_name, '')), '\s+', ' ', 'g'))
      || '|' || v_phone_key,
    0
  ));

  SELECT employee.id
  INTO v_duplicate_id
  FROM public.store_employees employee
  WHERE employee.store_id = NEW.store_id
    AND employee.id IS DISTINCT FROM NEW.id
    AND lower(regexp_replace(btrim(COALESCE(employee.full_name, '')), '\s+', ' ', 'g'))
      = lower(regexp_replace(btrim(COALESCE(NEW.full_name, '')), '\s+', ' ', 'g'))
    AND CASE
          WHEN regexp_replace(COALESCE(employee.phone, ''), '[^0-9]', '', 'g') LIKE '840%'
            THEN substr(regexp_replace(COALESCE(employee.phone, ''), '[^0-9]', '', 'g'), 3)
          WHEN regexp_replace(COALESCE(employee.phone, ''), '[^0-9]', '', 'g') LIKE '84%'
            AND length(regexp_replace(COALESCE(employee.phone, ''), '[^0-9]', '', 'g')) = 11
            THEN '0' || substr(regexp_replace(COALESCE(employee.phone, ''), '[^0-9]', '', 'g'), 3)
          ELSE regexp_replace(COALESCE(employee.phone, ''), '[^0-9]', '', 'g')
        END = v_phone_key
    AND lower(regexp_replace(COALESCE(employee.bank_name, ''), '\s+', '', 'g'))
      = lower(regexp_replace(COALESCE(NEW.bank_name, ''), '\s+', '', 'g'))
    AND lower(regexp_replace(COALESCE(employee.bank_account_number, ''), '[^a-zA-Z0-9]', '', 'g'))
      = lower(regexp_replace(COALESCE(NEW.bank_account_number, ''), '[^a-zA-Z0-9]', '', 'g'))
    AND lower(regexp_replace(btrim(COALESCE(employee.bank_account_holder, '')), '\s+', ' ', 'g'))
      = lower(regexp_replace(btrim(COALESCE(NEW.bank_account_holder, '')), '\s+', ' ', 'g'))
  ORDER BY employee.created_at
  LIMIT 1;

  IF v_duplicate_id IS NOT NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_DUPLICATE'
      USING DETAIL = v_duplicate_id::text,
            HINT = 'Edit or reactivate the existing employee instead of creating another account.';
  END IF;
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.part_timer_employee_name_token(text)
  FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.guard_duplicate_store_employee()
  FROM PUBLIC, anon, authenticated, service_role;

COMMIT;
