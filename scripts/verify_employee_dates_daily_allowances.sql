\set ON_ERROR_STOP on

DO $verify$
BEGIN
  IF to_regclass('public.employee_daily_allowances') IS NULL
     OR to_regprocedure(
       'public.create_store_employee_with_dates(uuid,text,text,text,text,text,text,date,date)'
     ) IS NULL
     OR to_regprocedure(
       'public.update_store_employee_with_dates(uuid,uuid,text,text,text,text,text,text,date,date)'
     ) IS NULL
     OR to_regprocedure(
       'public.create_store_part_timer_with_pay_rule_and_dates(uuid,text,text,text,text,text,numeric,date,time,time,numeric,numeric,integer,numeric)'
     ) IS NULL
     OR to_regprocedure(
       'public.upsert_employee_daily_allowance(uuid,uuid,date,boolean,numeric,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.save_photo_objet_daily_inventory_item_with_unit(uuid,uuid,text,numeric,text,date,text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_DATES_ALLOWANCES_OBJECT_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'store_employees'
      AND column_name = 'probation_start_date'
      AND data_type = 'date'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'store_employees'
      AND column_name = 'employment_start_date'
      AND data_type = 'date'
  ) THEN
    RAISE EXCEPTION 'EMPLOYMENT_DATE_COLUMNS_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.employee_daily_allowances'::regclass
      AND contype = 'u'
      AND pg_get_constraintdef(oid) LIKE '%store_id, employee_id, work_date%'
  ) THEN
    RAISE EXCEPTION 'EMPLOYEE_ALLOWANCE_DAILY_UNIQUENESS_MISSING';
  END IF;
END;
$verify$;

DO $verify$
BEGIN
  IF has_function_privilege(
       'anon',
       'public.upsert_employee_daily_allowance(uuid,uuid,date,boolean,numeric,text)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.upsert_employee_daily_allowance(uuid,uuid,date,boolean,numeric,text)',
       'EXECUTE'
     )
     OR has_table_privilege(
       'authenticated', 'public.employee_daily_allowances', 'INSERT'
     )
     OR NOT has_table_privilege(
       'authenticated', 'public.employee_daily_allowances', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'EMPLOYEE_ALLOWANCE_PRIVILEGE_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE oid = to_regprocedure(
      'public.upsert_employee_daily_allowance(uuid,uuid,date,boolean,numeric,text)'
    )
      AND pg_get_functiondef(oid) LIKE '%v_meal_allowance := 25000%'
      AND lower(pg_get_functiondef(oid)) LIKE '%asia/ho_chi_minh%'
  ) THEN
    RAISE EXCEPTION 'EMPLOYEE_ALLOWANCE_RULE_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.inventory_items'::regclass
      AND conname = 'inventory_items_unit_check'
      AND pg_get_constraintdef(oid) LIKE '%box%'
  ) THEN
    RAISE EXCEPTION 'PHOTO_INVENTORY_BOX_UNIT_MISSING';
  END IF;
END;
$verify$;

SELECT 'employee dates, daily allowances, and decimal inventory verification passed' AS result;
