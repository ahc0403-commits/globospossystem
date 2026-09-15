DO $verify$
DECLARE
  v_history_function regprocedure := to_regprocedure(
    'public.get_bm_menu_exception_history(uuid,timestamp with time zone,timestamp with time zone,text,boolean,text,timestamp with time zone,integer,integer)'
  );
  v_detail_function regprocedure := to_regprocedure(
    'public.get_bm_order_history_detail(uuid)'
  );
  v_history_definition text;
  v_detail_definition text;
BEGIN
  IF v_history_function IS NULL OR v_detail_function IS NULL THEN
    RAISE EXCEPTION 'BM history or original-order detail function is missing';
  END IF;

  SELECT pg_get_functiondef(v_history_function) INTO v_history_definition;
  SELECT pg_get_functiondef(v_detail_function) INTO v_detail_definition;

  IF v_history_definition NOT LIKE '%string_agg(%'
     OR v_history_definition NOT LIKE '%order_number%'
     OR v_history_definition NOT LIKE '%staff_meal_created%' THEN
    RAISE EXCEPTION 'BM staff-meal order grouping is missing';
  END IF;

  IF v_detail_definition NOT LIKE '%v_actor.role <> ''brand_admin''%'
     OR v_detail_definition NOT LIKE '%user_accessible_stores(auth.uid())%'
     OR v_detail_definition NOT LIKE '%order_item.item_type <> ''service_charge''%'
     OR v_detail_definition NOT LIKE '%BM_ORDER_HISTORY_NOT_FOUND%' THEN
    RAISE EXCEPTION 'BM original-order access or item contract is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE oid IN (v_history_function, v_detail_function)
      AND prosecdef
      AND provolatile = 's'
      AND proconfig @> ARRAY['search_path=pg_catalog, public, auth']::text[]
    HAVING count(*) = 2
  ) THEN
    RAISE EXCEPTION 'BM history function metadata is invalid';
  END IF;

  IF has_function_privilege('anon', v_history_function, 'EXECUTE')
     OR has_function_privilege('anon', v_detail_function, 'EXECUTE')
     OR NOT has_function_privilege(
       'authenticated', v_history_function, 'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated', v_detail_function, 'EXECUTE'
     )
     OR NOT has_function_privilege(
       'service_role', v_history_function, 'EXECUTE'
     )
     OR NOT has_function_privilege(
       'service_role', v_detail_function, 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'BM history function grants are invalid';
  END IF;
END;
$verify$;
