DO $$
DECLARE
  signature text;
  definition text;
BEGIN
  FOREACH signature IN ARRAY ARRAY[
    'public.get_bm_menu_exception_history(uuid,timestamptz,timestamptz,text,boolean,text,timestamptz,integer,integer)',
    'public.get_bm_order_history_detail(uuid)',
    'public.get_store_menu_sales_analytics(uuid,timestamptz,timestamptz,text)',
    'public.get_receipt_ledger(date,uuid,text,text,integer,integer)'
  ] LOOP
    definition := pg_get_functiondef(signature::regprocedure);
    IF definition NOT LIKE '%name_ko%' OR definition NOT LIKE '%name_en%' OR definition NOT LIKE '%name_vi%' THEN
      RAISE EXCEPTION 'Menu translation fields missing in %', signature;
    END IF;
    IF has_function_privilege('anon', signature, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', signature, 'EXECUTE')
       OR NOT has_function_privilege('service_role', signature, 'EXECUTE') THEN
      RAISE EXCEPTION 'Menu read function grants invalid for %', signature;
    END IF;
  END LOOP;
END $$;
DO $$
DECLARE
  signature text;
  definition text;
BEGIN
  FOREACH signature IN ARRAY ARRAY[
    'public.get_paperless_operations_report(uuid,timestamptz,timestamptz)',
    'public.get_paperless_operations_insights_report(uuid,timestamptz,timestamptz)'
  ] LOOP
    definition := pg_get_functiondef(signature::regprocedure);
    IF definition NOT LIKE '%pre_menu_localization%'
       OR definition NOT LIKE '%name_en%'
       OR definition NOT LIKE '%name_vi%'
       OR has_function_privilege('anon', signature, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', signature, 'EXECUTE') THEN
      RAISE EXCEPTION 'Paperless menu language contract invalid for %', signature;
    END IF;
  END LOOP;
END $$;
