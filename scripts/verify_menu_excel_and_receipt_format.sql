DO $verify$
DECLARE
  v_import_definition text;
  v_import_security_definer boolean;
  v_trigger_definition text;
  v_trigger_security_definer boolean;
BEGIN
  IF to_regprocedure(
       'public.admin_import_menu_items(uuid,jsonb)'
     ) IS NULL THEN
    RAISE EXCEPTION 'MENU_IMPORT_FUNCTION_MISSING';
  END IF;

  SELECT proc.prosecdef, pg_get_functiondef(proc.oid)
  INTO v_import_security_definer, v_import_definition
  FROM pg_proc proc
  WHERE proc.oid =
    'public.admin_import_menu_items(uuid,jsonb)'::regprocedure;

  IF NOT v_import_security_definer
     OR v_import_definition NOT LIKE '%require_admin_actor_for_restaurant%'
     OR v_import_definition NOT LIKE '%MENU_IMPORT_TOO_MANY_ROWS%'
     OR v_import_definition NOT LIKE '%excel_import%' THEN
    RAISE EXCEPTION 'MENU_IMPORT_DEFINITION_INVALID';
  END IF;

  IF NOT has_function_privilege(
       'authenticated',
       'public.admin_import_menu_items(uuid,jsonb)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.admin_import_menu_items(uuid,jsonb)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'public',
       'public.admin_import_menu_items(uuid,jsonb)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'MENU_IMPORT_PRIVILEGE_INVALID';
  END IF;

  IF to_regprocedure(
       'public.enrich_cashier_receipt_payload()'
     ) IS NULL THEN
    RAISE EXCEPTION 'CASHIER_RECEIPT_TRIGGER_FUNCTION_MISSING';
  END IF;

  SELECT proc.prosecdef, pg_get_functiondef(proc.oid)
  INTO v_trigger_security_definer, v_trigger_definition
  FROM pg_proc proc
  WHERE proc.oid =
    'public.enrich_cashier_receipt_payload()'::regprocedure;

  IF NOT v_trigger_security_definer
     OR v_trigger_definition NOT LIKE '%CÔNG TY TNHH AKJ INTERNATIONAL%'
     OR v_trigger_definition NOT LIKE '%0318453298%'
     OR v_trigger_definition NOT LIKE '%69/1A2 Nguyễn Gia Trí%'
     OR v_trigger_definition NOT LIKE '%receipt_number%'
     OR v_trigger_definition NOT LIKE '%cashier_code%' THEN
    RAISE EXCEPTION 'CASHIER_RECEIPT_TRIGGER_DEFINITION_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    JOIN pg_class relation ON relation.oid = trigger_row.tgrelid
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname = 'print_jobs'
      AND trigger_row.tgname = 'enrich_cashier_receipt_payload_trigger'
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'CASHIER_RECEIPT_TRIGGER_MISSING_OR_DISABLED';
  END IF;
END
$verify$;

SELECT 'MENU_EXCEL_RECEIPT_VERIFY_OK';
