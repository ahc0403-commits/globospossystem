CREATE OR REPLACE FUNCTION public.get_restaurant_daily_sales_export(
  p_business_date date
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_finalization public.restaurant_daily_sales_finalizations%ROWTYPE;
  v_receipts jsonb := '[]'::jsonb;
BEGIN
  IF p_business_date IS NULL THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'RESTAURANT_SALES_EXPORT_DATE_REQUIRED';
  END IF;

  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'RESTAURANT_SALES_EXPORT_FORBIDDEN';
  END IF;

  SELECT finalization.* INTO v_finalization
  FROM public.restaurant_daily_sales_finalizations finalization
  WHERE finalization.business_date = p_business_date;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'business_date', p_business_date,
      'status', 'pending',
      'receipts', '[]'::jsonb
    );
  END IF;

  IF v_finalization.status = 'finalized' THEN
    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'store_id', receipt.store_id,
          'store_name', store.name,
          'receipt_id', receipt.receipt_id,
          'receipt_source', receipt.receipt_source,
          'sales_channel', receipt.sales_channel,
          'gross_sales', receipt.gross_sales,
          'sold_at', receipt.sold_at,
          'sale_hour_hcm', receipt.sale_hour_hcm
        ) ORDER BY receipt.sold_at, receipt.receipt_id
      ),
      '[]'::jsonb
    ) INTO v_receipts
    FROM public.v_restaurant_sales_receipts receipt
    JOIN public.restaurants store ON store.id = receipt.store_id
    WHERE receipt.sale_date_hcm = p_business_date;
  END IF;

  RETURN jsonb_build_object(
    'business_date', v_finalization.business_date,
    'status', v_finalization.status,
    'store_count', v_finalization.store_count,
    'receipt_count', v_finalization.receipt_count,
    'gross_sales', v_finalization.gross_sales,
    'post_cutoff_receipt_count',
      v_finalization.post_cutoff_receipt_count,
    'finalized_at', v_finalization.finalized_at,
    'receipts', v_receipts
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_restaurant_daily_sales_export(date)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_restaurant_daily_sales_export(date)
  TO authenticated;

COMMENT ON FUNCTION public.get_restaurant_daily_sales_export(date) IS
  'Super-admin read-only export of the immutable legal-entity Restaurant daily finalization and receipt timestamps.';
