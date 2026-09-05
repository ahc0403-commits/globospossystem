DO $$
DECLARE v_relation text;
BEGIN
  FOREACH v_relation IN ARRAY ARRAY['payments', 'orders', 'external_sales', 'v_photo_objet_daily_summary', 'order_items', 'meinvoice_jobs'] LOOP
    IF to_regclass('public.' || v_relation) IS NULL THEN
      RAISE EXCEPTION 'STORE_REVENUE_PREREQUISITE_MISSING: %', v_relation;
    END IF;
  END LOOP;
  IF to_regprocedure('public.user_accessible_stores(uuid)') IS NULL
    OR to_regprocedure('public.is_super_admin()') IS NULL THEN
    RAISE EXCEPTION 'STORE_REVENUE_SCOPE_HELPERS_MISSING';
  END IF;
  IF to_regprocedure('public.get_store_sales_cancellation_total(uuid,timestamptz,timestamptz)') IS NULL THEN
    RAISE EXCEPTION 'STORE_REPORT_CANCELLATION_HELPER_MISSING';
  END IF;
  -- Validate the actual projections without reading business rows.
  PERFORM p.restaurant_id, p.order_id, p.amount_portion, p.amount, p.is_revenue, p.created_at
    FROM public.payments p WHERE false;
  PERFORM o.id, o.sales_channel FROM public.orders o WHERE false;
  PERFORM e.restaurant_id, e.net_amount, e.is_revenue, e.order_status, e.completed_at
    FROM public.external_sales e WHERE false;
  PERFORM f.store_id, f.sale_date, f.total_gross_sales, f.total_service_amount
    FROM public.v_photo_objet_daily_summary f WHERE false;
END;
$$;
