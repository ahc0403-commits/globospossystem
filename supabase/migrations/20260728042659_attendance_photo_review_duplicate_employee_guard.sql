-- Prevent concurrent or API-level creation of the same employee identity
-- within one store. The UI performs the same check to offer an edit path,
-- while this trigger is the authoritative race-safe guard.
CREATE OR REPLACE FUNCTION public.guard_duplicate_store_employee()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_identity_key text;
  v_phone_key text;
  v_duplicate_id uuid;
BEGIN
  v_phone_key := regexp_replace(COALESCE(NEW.phone, ''), '[^0-9]', '', 'g');
  IF v_phone_key LIKE '840%' THEN
    v_phone_key := substr(v_phone_key, 3);
  ELSIF v_phone_key LIKE '84%' AND length(v_phone_key) = 11 THEN
    v_phone_key := '0' || substr(v_phone_key, 3);
  END IF;

  v_identity_key := concat_ws(
    '|',
    lower(regexp_replace(btrim(COALESCE(NEW.full_name, '')), '\s+', ' ', 'g')),
    v_phone_key,
    lower(regexp_replace(COALESCE(NEW.bank_name, ''), '\s+', '', 'g')),
    lower(regexp_replace(COALESCE(NEW.bank_account_number, ''), '[^a-zA-Z0-9]', '', 'g')),
    lower(regexp_replace(btrim(COALESCE(NEW.bank_account_holder, '')), '\s+', ' ', 'g'))
  );

  PERFORM pg_advisory_xact_lock(
    hashtextextended(NEW.store_id::text || '|' || v_identity_key, 0)
  );

  SELECT employee.id
  INTO v_duplicate_id
  FROM public.store_employees employee
  WHERE employee.store_id = NEW.store_id
    AND employee.is_active = TRUE
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
            HINT = 'Edit the existing employee instead of creating another account.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS store_employee_duplicate_guard_before_insert
  ON public.store_employees;
CREATE TRIGGER store_employee_duplicate_guard_before_insert
BEFORE INSERT ON public.store_employees
FOR EACH ROW
EXECUTE FUNCTION public.guard_duplicate_store_employee();

REVOKE ALL ON FUNCTION public.guard_duplicate_store_employee()
  FROM PUBLIC, anon, authenticated, service_role;
