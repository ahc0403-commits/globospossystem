DO $preflight$
DECLARE
  v_relation text;
BEGIN
  FOREACH v_relation IN ARRAY ARRAY[
    'public.orders',
    'public.restaurants',
    'public.tax_entity',
    'public.meinvoice_jobs',
    'public.meinvoice_tax_entity_config',
    'public.payments',
    'public.order_items',
    'public.b2b_buyer_cache',
    'public.audit_logs',
    'public.restaurant_daily_sales_finalizations',
    'public.users',
    'storage.buckets',
    'storage.objects'
  ] LOOP
    IF to_regclass(v_relation) IS NULL THEN
      RAISE EXCEPTION 'RED_INVOICE_BASE_RELATION_MISSING:%', v_relation;
    END IF;
  END LOOP;

  IF to_regprocedure('public.is_super_admin()') IS NULL
     OR to_regprocedure('public.user_accessible_stores(uuid)') IS NULL
     OR to_regprocedure(
       'public.meinvoice_payment_method_label(uuid,text[])'
     ) IS NULL THEN
    RAISE EXCEPTION 'RED_INVOICE_BASE_FUNCTION_MISSING';
  END IF;
END
$preflight$;

SELECT 'RED_INVOICE_INTAKE_EXPORT_PREFLIGHT_OK';
