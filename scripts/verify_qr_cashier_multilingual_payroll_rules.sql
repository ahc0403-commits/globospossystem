DO $verify$
DECLARE
  v_definition text;
  v_holiday_dates date[];
  v_constraint text;
BEGIN
  IF (
    SELECT count(*)
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name IN ('menu_categories', 'menu_items')
      AND column_name IN ('name_ko', 'name_vi', 'name_en')
      AND data_type = 'text'
  ) <> 6 THEN
    RAISE EXCEPTION 'QR_PAYROLL_VERIFY_MENU_COLUMNS_INCOMPLETE';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.menu_categories
    WHERE NULLIF(btrim(name_ko), '') IS NULL
       OR NULLIF(btrim(name_vi), '') IS NULL
       OR NULLIF(btrim(name_en), '') IS NULL
  ) OR EXISTS (
    SELECT 1 FROM public.menu_items
    WHERE NULLIF(btrim(name_ko), '') IS NULL
       OR NULLIF(btrim(name_vi), '') IS NULL
       OR NULLIF(btrim(name_en), '') IS NULL
  ) THEN
    RAISE EXCEPTION 'QR_PAYROLL_VERIFY_MENU_BACKFILL_INCOMPLETE';
  END IF;

  IF to_regclass('public.employee_hourly_pay_rules') IS NULL
     OR to_regclass('public.vietnam_public_holidays') IS NULL THEN
    RAISE EXCEPTION 'QR_PAYROLL_VERIFY_RULE_TABLES_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_class
    WHERE oid = 'public.employee_hourly_pay_rules'::regclass
      AND relrowsecurity
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_class
    WHERE oid = 'public.vietnam_public_holidays'::regclass
      AND relrowsecurity
  ) THEN
    RAISE EXCEPTION 'QR_PAYROLL_VERIFY_RLS_DISABLED';
  END IF;

  IF to_regprocedure('public.admin_create_menu_category_i18n(uuid,text,text,text,integer)') IS NULL
     OR to_regprocedure('public.admin_update_menu_category_i18n(uuid,text,text,text)') IS NULL
     OR to_regprocedure('public.admin_create_menu_item_i18n(uuid,uuid,text,text,text,numeric,integer,boolean)') IS NULL
     OR to_regprocedure('public.admin_update_menu_item_i18n(uuid,text,text,text,numeric)') IS NULL
     OR to_regprocedure('public.upsert_employee_hourly_pay_rule(uuid,uuid,numeric,time,time,numeric,numeric,boolean,integer,numeric)') IS NULL
     OR to_regprocedure('public.create_store_part_timer_with_pay_rule(uuid,text,text,text,text,text,numeric,time,time,numeric,numeric,integer,numeric)') IS NULL THEN
    RAISE EXCEPTION 'QR_PAYROLL_VERIFY_RPCS_MISSING';
  END IF;

  IF (
    SELECT count(*) FROM pg_trigger
    WHERE tgname IN (
      'qr_order_item_ready_before_insert',
      'qr_order_skip_duplicate_floor_print',
      'clear_hourly_pay_rule_for_non_part_timer'
    ) AND NOT tgisinternal AND tgenabled <> 'D'
  ) <> 3 THEN
    RAISE EXCEPTION 'QR_PAYROLL_VERIFY_TRIGGERS_INCOMPLETE';
  END IF;

  SELECT pg_get_functiondef(
    'public.qr_order_item_ready_before_insert()'::regprocedure
  ) INTO v_definition;
  IF v_definition NOT LIKE '%NEW.status := ''ready''%'
     OR v_definition NOT LIKE '%o.order_source = ''qr''%' THEN
    RAISE EXCEPTION 'QR_PAYROLL_VERIFY_QR_CASHIER_FLOW_INCORRECT';
  END IF;

  SELECT pg_get_functiondef(
    'public.qr_order_skip_duplicate_floor_print()'::regprocedure
  ) INTO v_definition;
  IF v_definition NOT LIKE '%NEW.copy_type = ''floor''%'
     OR v_definition NOT LIKE '%RETURN NULL%' THEN
    RAISE EXCEPTION 'QR_PAYROLL_VERIFY_PRINT_FLOW_INCORRECT';
  END IF;

  SELECT pg_get_functiondef('public.qr_get_menu(text)'::regprocedure)
  INTO v_definition;
  IF v_definition NOT LIKE '%''name_ko''%'
     OR v_definition NOT LIKE '%''name_vi''%'
     OR v_definition NOT LIKE '%''name_en''%' THEN
    RAISE EXCEPTION 'QR_PAYROLL_VERIFY_QR_MENU_I18N_INCOMPLETE';
  END IF;

  SELECT array_agg(holiday_date ORDER BY holiday_date)
  INTO v_holiday_dates
  FROM public.vietnam_public_holidays
  WHERE is_active AND holiday_date BETWEEN DATE '2026-01-01' AND DATE '2026-12-31';
  IF v_holiday_dates IS DISTINCT FROM ARRAY[
    DATE '2026-01-01',
    DATE '2026-02-16', DATE '2026-02-17', DATE '2026-02-18',
    DATE '2026-02-19', DATE '2026-02-20',
    DATE '2026-04-26', DATE '2026-04-30', DATE '2026-05-01',
    DATE '2026-09-01', DATE '2026-09-02'
  ] THEN
    RAISE EXCEPTION 'QR_PAYROLL_VERIFY_2026_HOLIDAYS_INCORRECT';
  END IF;

  SELECT pg_get_constraintdef(oid)
  INTO v_constraint
  FROM pg_constraint
  WHERE conrelid = 'public.employee_hourly_pay_rules'::regclass
    AND conname = 'employee_hourly_pay_rules_holiday_multiplier_check';
  IF v_constraint IS NULL
     OR v_constraint NOT LIKE '%holiday_multiplier >= (3)::numeric%' THEN
    RAISE EXCEPTION 'QR_PAYROLL_VERIFY_HOLIDAY_MINIMUM_MISSING';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.admin_create_menu_item_i18n(uuid,uuid,text,text,text,numeric,integer,boolean)',
    'EXECUTE'
  ) OR has_function_privilege(
    'anon',
    'public.admin_create_menu_item_i18n(uuid,uuid,text,text,text,numeric,integer,boolean)',
    'EXECUTE'
  ) OR NOT has_function_privilege(
    'authenticated',
    'public.upsert_employee_hourly_pay_rule(uuid,uuid,numeric,time,time,numeric,numeric,boolean,integer,numeric)',
    'EXECUTE'
  ) OR has_function_privilege(
    'anon',
    'public.upsert_employee_hourly_pay_rule(uuid,uuid,numeric,time,time,numeric,numeric,boolean,integer,numeric)',
    'EXECUTE'
  ) OR has_function_privilege(
    'authenticated',
    'public.qr_order_item_ready_before_insert()',
    'EXECUTE'
  ) OR has_function_privilege(
    'authenticated',
    'public.qr_order_skip_duplicate_floor_print()',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'QR_PAYROLL_VERIFY_FUNCTION_GRANTS_INCORRECT';
  END IF;

  IF NOT has_table_privilege(
    'authenticated', 'public.employee_hourly_pay_rules', 'SELECT'
  ) OR has_table_privilege(
    'authenticated', 'public.employee_hourly_pay_rules', 'INSERT'
  ) OR has_table_privilege(
    'authenticated', 'public.employee_hourly_pay_rules', 'UPDATE'
  ) OR has_table_privilege(
    'authenticated', 'public.employee_hourly_pay_rules', 'DELETE'
  ) OR NOT has_table_privilege(
    'authenticated', 'public.vietnam_public_holidays', 'SELECT'
  ) OR has_table_privilege(
    'authenticated', 'public.vietnam_public_holidays', 'INSERT'
  ) OR has_table_privilege(
    'authenticated', 'public.vietnam_public_holidays', 'UPDATE'
  ) OR has_table_privilege(
    'authenticated', 'public.vietnam_public_holidays', 'DELETE'
  ) OR has_table_privilege(
    'anon', 'public.vietnam_public_holidays', 'SELECT'
  ) THEN
    RAISE EXCEPTION 'QR_PAYROLL_VERIFY_TABLE_GRANTS_INCORRECT';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'employee_hourly_pay_rules'
      AND policyname = 'employee_hourly_pay_rules_manager_read'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'vietnam_public_holidays'
      AND policyname = 'vietnam_public_holidays_authenticated_read'
  ) THEN
    RAISE EXCEPTION 'QR_PAYROLL_VERIFY_POLICIES_MISSING';
  END IF;
END;
$verify$;
