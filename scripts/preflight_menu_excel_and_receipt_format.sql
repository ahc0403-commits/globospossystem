DO $preflight$
DECLARE
  v_relation text;
BEGIN
  FOREACH v_relation IN ARRAY ARRAY[
    'public.menu_categories',
    'public.menu_items',
    'public.audit_logs',
    'public.print_jobs',
    'public.orders',
    'public.restaurants',
    'public.brands',
    'public.tax_entity',
    'public.payments',
    'public.users',
    'public.order_items',
    'public.order_discounts'
  ] LOOP
    IF to_regclass(v_relation) IS NULL THEN
      RAISE EXCEPTION 'MENU_RECEIPT_BASE_RELATION_MISSING:%', v_relation;
    END IF;
  END LOOP;

  IF to_regprocedure(
       'public.require_admin_actor_for_restaurant(uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'MENU_IMPORT_AUTH_HELPER_MISSING';
  END IF;
END
$preflight$;

SELECT 'MENU_EXCEL_RECEIPT_PREFLIGHT_OK';
