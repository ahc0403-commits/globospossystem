\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_function regprocedure;
  v_config text[];
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_items'
      AND column_name = 'is_combo'
      AND data_type = 'boolean'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'order_items'
      AND column_name = 'combo_components'
      AND data_type = 'jsonb'
  ) THEN
    RAISE EXCEPTION 'COMBO_MENU_COLUMNS_MISSING';
  END IF;

  IF to_regclass('public.menu_combo_components') IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM pg_class
       WHERE oid = 'public.menu_combo_components'::regclass
         AND relrowsecurity
     ) THEN
    RAISE EXCEPTION 'COMBO_MENU_COMPONENT_TABLE_OR_RLS_MISSING';
  END IF;

  FOREACH v_function IN ARRAY ARRAY[
    'public.admin_reorder_menu_categories(uuid,uuid[])'::regprocedure,
    'public.admin_set_menu_combo(uuid,boolean,jsonb)'::regprocedure
  ]
  LOOP
    SELECT proconfig INTO v_config FROM pg_proc WHERE oid = v_function;
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = v_function AND prosecdef)
       OR NOT ('search_path=public, auth' = ANY(v_config))
       OR has_function_privilege('anon', v_function, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', v_function, 'EXECUTE') THEN
      RAISE EXCEPTION 'COMBO_MENU_FUNCTION_SECURITY_INVALID: %', v_function;
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    JOIN pg_class relation ON relation.oid = trigger_row.tgrelid
    WHERE relation.oid = 'public.order_items'::regclass
      AND trigger_row.tgname = 'snapshot_order_item_combo_components_trigger'
      AND trigger_row.tgenabled <> 'D'
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    JOIN pg_class relation ON relation.oid = trigger_row.tgrelid
    WHERE relation.oid = 'public.menu_items'::regclass
      AND trigger_row.tgname = 'prevent_combo_component_menu_delete_trigger'
      AND trigger_row.tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'COMBO_MENU_TRIGGER_MISSING_OR_DISABLED';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'menu_combo_components_store_idx'
  ) THEN
    RAISE EXCEPTION 'COMBO_MENU_INDEX_MISSING';
  END IF;

  IF has_function_privilege(
       'authenticated',
       'public.enqueue_print_jobs(uuid,text[],jsonb,text)',
       'EXECUTE'
     ) OR has_function_privilege(
       'anon',
       'public.enqueue_print_jobs(uuid,text[],jsonb,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PRINT_ENQUEUE_PRIVILEGE_INVALID';
  END IF;
END
$verify$;

SELECT 'category reordering and combo menu verification passed' AS result;
