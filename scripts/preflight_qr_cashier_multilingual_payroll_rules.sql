DO $preflight$
DECLARE
  v_qr_definition text;
BEGIN
  IF to_regclass('public.menu_categories') IS NULL
     OR to_regclass('public.menu_items') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.order_items') IS NULL
     OR to_regclass('public.print_jobs') IS NULL
     OR to_regclass('public.store_employees') IS NULL
     OR to_regclass('public.restaurants') IS NULL
     OR to_regclass('public.audit_logs') IS NULL THEN
    RAISE EXCEPTION 'QR_PAYROLL_PREFLIGHT_BASE_TABLES_MISSING';
  END IF;

  IF to_regprocedure('public.require_admin_actor_for_restaurant(uuid)') IS NULL
     OR to_regprocedure('public.require_workforce_manager(uuid)') IS NULL
     OR to_regprocedure('public.workforce_can_manage_store(uuid)') IS NULL
     OR to_regprocedure('public.create_store_employee(uuid,text,text,text,text,text,text)') IS NULL
     OR to_regprocedure('public.qr_get_menu(text)') IS NULL
     OR to_regprocedure('public.qr_place_order(text,jsonb,uuid)') IS NULL
     OR to_regprocedure('public.recalc_order_status(uuid)') IS NULL THEN
    RAISE EXCEPTION 'QR_PAYROLL_PREFLIGHT_DEPENDENCY_RPC_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'orders'
      AND column_name = 'order_source'
  ) THEN
    RAISE EXCEPTION 'QR_PAYROLL_PREFLIGHT_ORDER_SOURCE_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.qr_place_order(text,jsonb,uuid)'::regprocedure
  ) INTO v_qr_definition;
  IF v_qr_definition NOT LIKE '%ARRAY[''kitchen'', ''floor'', ''confirmation'']%' THEN
    RAISE EXCEPTION 'QR_PAYROLL_PREFLIGHT_PRINT_CONTRACT_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name IN ('menu_categories', 'menu_items')
      AND column_name IN ('name_ko', 'name_vi', 'name_en')
  )
  OR to_regclass('public.employee_hourly_pay_rules') IS NOT NULL
  OR to_regclass('public.vietnam_public_holidays') IS NOT NULL
  OR to_regprocedure('public.admin_create_menu_category_i18n(uuid,text,text,text,integer)') IS NOT NULL
  OR to_regprocedure('public.admin_create_menu_item_i18n(uuid,uuid,text,text,text,numeric,integer,boolean)') IS NOT NULL
  OR EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgname IN (
      'qr_order_item_ready_before_insert',
      'qr_order_skip_duplicate_floor_print',
      'clear_hourly_pay_rule_for_non_part_timer'
    ) AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'QR_PAYROLL_PREFLIGHT_PARTIAL_STATE_DETECTED';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.menu_categories WHERE NULLIF(btrim(name), '') IS NULL
  ) OR EXISTS (
    SELECT 1 FROM public.menu_items WHERE NULLIF(btrim(name), '') IS NULL
  ) THEN
    RAISE EXCEPTION 'QR_PAYROLL_PREFLIGHT_LEGACY_MENU_NAME_INVALID';
  END IF;
END;
$preflight$;
