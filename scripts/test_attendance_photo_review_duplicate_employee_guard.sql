\set ON_ERROR_STOP on

BEGIN;

DO $test$
DECLARE
  v_store_id uuid;
  v_creator_id uuid;
  v_first_id uuid;
  v_duplicate_blocked boolean := false;
BEGIN
  SELECT restaurant.id
  INTO v_store_id
  FROM public.restaurants restaurant
  WHERE restaurant.is_active = TRUE
    AND restaurant.short_code IS NOT NULL
  ORDER BY restaurant.created_at
  LIMIT 1;

  IF v_store_id IS NULL THEN
    RAISE EXCEPTION 'DUPLICATE_EMPLOYEE_TEST_STORE_MISSING';
  END IF;

  SELECT actor.id
  INTO v_creator_id
  FROM public.users actor
  WHERE actor.restaurant_id = v_store_id
  ORDER BY actor.created_at
  LIMIT 1;

  INSERT INTO public.store_employees(
    store_id,
    employee_number,
    full_name,
    employment_role,
    phone,
    bank_name,
    bank_account_number,
    bank_account_holder,
    created_by_user_id
  ) VALUES (
    v_store_id,
    'ZZ998001',
    'Codex Duplicate Guard',
    'part_timer',
    '+84 090-123-4567',
    'Vietcom Bank',
    '123-456-789',
    'CODEX DUPLICATE GUARD',
    v_creator_id
  ) RETURNING id INTO v_first_id;

  BEGIN
    INSERT INTO public.store_employees(
      store_id,
      employee_number,
      full_name,
      employment_role,
      phone,
      bank_name,
      bank_account_number,
      bank_account_holder,
      created_by_user_id
    ) VALUES (
      v_store_id,
      'ZZ998002',
      ' codex  duplicate guard ',
      'manager',
      '0901234567',
      'VIETCOMBANK',
      '123456789',
      'codex duplicate guard',
      v_creator_id
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM = 'EMPLOYEE_DUPLICATE' THEN
        v_duplicate_blocked := true;
      ELSE
        RAISE;
      END IF;
  END;

  IF NOT v_duplicate_blocked THEN
    RAISE EXCEPTION 'DUPLICATE_EMPLOYEE_WAS_NOT_BLOCKED';
  END IF;
END
$test$;

ROLLBACK;

SELECT 'attendance photo review and duplicate employee guard integration passed'
  AS result;
