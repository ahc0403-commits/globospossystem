\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_definition text;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc proc
    WHERE proc.oid =
      'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone,text)'::regprocedure
      AND proc.prosecdef
      AND proc.provolatile = 's'
      AND proc.prorettype = 'jsonb'::regtype
      AND proc.proconfig @>
        ARRAY['search_path=public, auth, pg_catalog']::text[]
  ) THEN
    RAISE EXCEPTION 'MENU_SALES_SCOPE_RPC_SECURITY_INVALID';
  END IF;

  IF has_function_privilege(
       'anon',
       'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone,text)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone,text)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'service_role',
       'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'MENU_SALES_SCOPE_RPC_PRIVILEGE_INVALID';
  END IF;

  v_definition := lower(pg_get_functiondef(
    'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone,text)'::regprocedure
  ));
  IF v_definition NOT LIKE '%require_admin_actor_for_restaurant(p_store_id)%'
     OR v_definition NOT LIKE '%v_menu_scope not in (''all'', ''regular'', ''combo'')%'
     OR v_definition NOT LIKE '%when ''regular'' then jsonb_array_length%'
     OR v_definition NOT LIKE '%when ''combo'' then jsonb_array_length%'
     OR v_definition NOT LIKE '%''combo_menu_sales_amount''%'
     OR v_definition NOT LIKE '%''menu_scope''%'
     OR v_definition NOT LIKE '%item.combo_components%'
     OR v_definition NOT LIKE '%at time zone ''asia/ho_chi_minh''%'
     OR v_definition NOT LIKE '%payment.is_revenue = true%'
     OR v_definition NOT LIKE '%order_row.status = ''completed''%' THEN
    RAISE EXCEPTION 'MENU_SALES_SCOPE_QUERY_CONTRACT_INVALID';
  END IF;

  IF to_regprocedure(
       'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone)'
     ) IS NULL
     OR to_regprocedure(
       'public.get_store_menu_sales_analytics(uuid,timestamp with time zone,timestamp with time zone,boolean)'
     ) IS NULL THEN
    RAISE EXCEPTION 'MENU_SALES_SCOPE_COMPATIBILITY_INVALID';
  END IF;
END
$verify$;

SELECT 'MENU_SALES_SCOPE_COMBO_REVENUE_VERIFY_OK' AS result;
