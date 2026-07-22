DO $verify$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
    'public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb)'
  ) IS NULL THEN
    RAISE EXCEPTION 'MENU_ROUNDTRIP_VERIFY_RPC_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb)'::regprocedure
  ) INTO v_definition;
  IF v_definition NOT LIKE '%require_admin_actor_for_restaurant%'
     OR v_definition NOT LIKE '%MENU_WORKBOOK_STORE_MISMATCH%'
     OR v_definition NOT LIKE '%MENU_WORKBOOK_ITEM_CATEGORY_MISMATCH%'
     OR v_definition NOT LIKE '%name_ko = v_name_ko%'
     OR v_definition NOT LIKE '%name_vi = v_name_vi%'
     OR v_definition NOT LIKE '%name_en = v_name_en%'
     OR v_definition LIKE '%image_url =%' THEN
    RAISE EXCEPTION 'MENU_ROUNDTRIP_VERIFY_RPC_CONTRACT_INCORRECT';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb)',
    'EXECUTE'
  ) OR has_function_privilege(
    'anon',
    'public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'MENU_ROUNDTRIP_VERIFY_RPC_GRANTS_INCORRECT';
  END IF;
END;
$verify$;
