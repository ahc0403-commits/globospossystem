DO $verify$
DECLARE
  v_definition text;
  v_security_definer boolean;
BEGIN
  IF to_regprocedure(
    'public.get_restaurant_daily_sales_export(date)'
  ) IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_EXPORT_FUNCTION_MISSING';
  END IF;

  SELECT proc.prosecdef, pg_get_functiondef(proc.oid)
  INTO v_security_definer, v_definition
  FROM pg_proc proc
  WHERE proc.oid =
    'public.get_restaurant_daily_sales_export(date)'::regprocedure;

  IF NOT v_security_definer
     OR v_definition NOT LIKE '%public.is_super_admin()%'
     OR v_definition NOT LIKE '%restaurant_daily_sales_finalizations%'
     OR v_definition NOT LIKE '%v_restaurant_sales_receipts%'
     OR v_definition NOT LIKE '%RESTAURANT_SALES_EXPORT_FORBIDDEN%' THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_EXPORT_DEFINITION_INVALID';
  END IF;

  IF NOT has_function_privilege(
       'authenticated',
       'public.get_restaurant_daily_sales_export(date)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.get_restaurant_daily_sales_export(date)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'service_role',
       'public.get_restaurant_daily_sales_export(date)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'public',
       'public.get_restaurant_daily_sales_export(date)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_EXPORT_PRIVILEGE_INVALID';
  END IF;
END
$verify$;

SELECT 'RESTAURANT_SALES_EXPORT_VERIFY_OK';
