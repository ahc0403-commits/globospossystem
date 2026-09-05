DO $$
DECLARE v_relation text;
BEGIN
  FOREACH v_relation IN ARRAY ARRAY['store_employees', 'employee_daily_allowances',
    'vietnam_public_holidays', 'payments', 'orders', 'order_items', 'external_sales',
    'v_photo_objet_daily_summary', 'meinvoice_jobs'] LOOP
    IF to_regclass('public.' || v_relation) IS NULL THEN
      RAISE EXCEPTION 'FINANCIAL_INPUT_PREREQUISITE_MISSING: %', v_relation;
    END IF;
  END LOOP;
  IF to_regprocedure('public.user_accessible_stores(uuid)') IS NULL
     OR to_regprocedure('public.is_super_admin()') IS NULL THEN
    RAISE EXCEPTION 'FINANCIAL_INPUT_SCOPE_HELPERS_MISSING';
  END IF;
END;
$$;
