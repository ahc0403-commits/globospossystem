BEGIN;

-- production-gate: self-verifying

-- The business day is globally fixed to Asia/Ho_Chi_Minh. A store-specific
-- cutoff-policy row must not decide whether a paid Restaurant receipt exists.
CREATE OR REPLACE FUNCTION public.get_restaurant_daily_sales_export(
  p_business_date date
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_finalization public.restaurant_daily_sales_finalizations%ROWTYPE;
  v_receipts jsonb := '[]'::jsonb;
  v_store_count integer := 0;
  v_receipt_count integer := 0;
  v_gross_sales numeric(18,2) := 0;
  v_start timestamptz;
  v_end timestamptz;
  v_photo_objet_brand_id constant uuid :=
    '77000000-0000-0000-0000-000000000001';
BEGIN
  IF p_business_date IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_EXPORT_DATE_REQUIRED';
  END IF;
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_EXPORT_FORBIDDEN';
  END IF;

  SELECT * INTO v_finalization
  FROM public.restaurant_daily_sales_finalizations finalization
  WHERE finalization.business_date = p_business_date;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'business_date', p_business_date,
      'status', 'pending',
      'receipts', '[]'::jsonb
    );
  END IF;
  IF v_finalization.status <> 'finalized' THEN
    RETURN jsonb_build_object(
      'business_date', v_finalization.business_date,
      'status', v_finalization.status,
      'receipts', '[]'::jsonb
    );
  END IF;

  v_start := p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_end := (p_business_date + 1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';

  WITH paid_orders AS (
    SELECT
      payment.order_id,
      payment.restaurant_id AS store_id,
      max(payment.created_at) AS sold_at,
      round(sum(COALESCE(payment.amount_portion, payment.amount)), 2)
        AS gross_sales,
      array_agg(DISTINCT payment.method ORDER BY payment.method)
        AS payment_methods
    FROM public.payments payment
    JOIN public.orders issued_order
      ON issued_order.id = payment.order_id
     AND issued_order.status = 'completed'
    JOIN public.restaurants restaurant
      ON restaurant.id = payment.restaurant_id
     AND restaurant.brand_id IS DISTINCT FROM v_photo_objet_brand_id
    WHERE payment.is_revenue = true
    GROUP BY payment.order_id, payment.restaurant_id
    HAVING max(payment.created_at) >= v_start
       AND max(payment.created_at) < v_end
  ),
  report_rows AS (
    SELECT
      paid.order_id::text AS receipt_id,
      paid.store_id,
      restaurant.name AS store_name,
      'pos_payment'::text AS receipt_source,
      'restaurant_pos'::text AS source_system,
      orders.sales_channel,
      paid.sold_at,
      paid.gross_sales,
      COALESCE(
        NULLIF(btrim(job.payment_method_snapshot), ''),
        public.meinvoice_payment_method_label(
          restaurant.tax_entity_id,
          paid.payment_methods
        )
      ) AS payment_method,
      intake.id IS NOT NULL AND intake.status <> 'cancelled'
        AS is_red_invoice,
      COALESCE(intake.status, '') AS red_invoice_status,
      COALESCE(intake.buyer_tax_code, '') AS buyer_tax_code,
      COALESCE(intake.buyer_legal_name, '') AS buyer_legal_name,
      COALESCE(intake.buyer_address, '') AS buyer_address,
      COALESCE(
        NULLIF(job.line_items_snapshot, '[]'::jsonb),
        order_lines.line_items,
        '[]'::jsonb
      ) AS line_items
    FROM paid_orders paid
    JOIN public.orders orders ON orders.id = paid.order_id
    JOIN public.restaurants restaurant ON restaurant.id = paid.store_id
    LEFT JOIN public.red_invoice_intakes intake
      ON intake.order_id = paid.order_id
    LEFT JOIN LATERAL (
      SELECT candidate.payment_method_snapshot, candidate.line_items_snapshot
      FROM public.meinvoice_jobs candidate
      WHERE candidate.order_id = paid.order_id
        AND candidate.source_system = 'restaurant_pos'
      ORDER BY candidate.created_at DESC, candidate.id DESC
      LIMIT 1
    ) job ON true
    LEFT JOIN LATERAL (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'display_name', COALESCE(
          NULLIF(item.display_name, ''), NULLIF(item.label, ''), 'Món ăn'
        ),
        'quantity', item.quantity,
        'unit_price', item.unit_price,
        'total_amount_ex_tax', item.total_amount_ex_tax,
        'vat_rate', item.vat_rate,
        'vat_amount', item.vat_amount
      ) ORDER BY item.created_at, item.id), '[]'::jsonb) AS line_items
      FROM public.order_items item
      WHERE item.order_id = paid.order_id
        AND item.status <> 'cancelled'
        AND COALESCE(item.is_service_item, false) = false
    ) order_lines ON true
  )
  SELECT
    COALESCE(jsonb_agg(to_jsonb(report_rows)
      ORDER BY report_rows.sold_at, report_rows.receipt_id), '[]'::jsonb),
    count(DISTINCT report_rows.store_id)::integer,
    count(*)::integer,
    round(COALESCE(sum(report_rows.gross_sales), 0), 2)
  INTO v_receipts, v_store_count, v_receipt_count, v_gross_sales
  FROM report_rows;

  RETURN jsonb_build_object(
    'business_date', v_finalization.business_date,
    'status', v_finalization.status,
    'store_count', v_store_count,
    'receipt_count', v_receipt_count,
    'gross_sales', v_gross_sales,
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
  'Super-admin unified MISA workbook source for every finalized Restaurant POS receipt; global HCM day, excludes Photo Objet and external settlements.';

DO $verification$
DECLARE
  v_export regprocedure :=
    'public.get_restaurant_daily_sales_export(date)'::regprocedure;
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(v_export::oid) INTO v_definition;
  IF position('restaurant_cutoff_policies' IN v_definition) > 0
     OR position('Asia/Ho_Chi_Minh' IN v_definition) = 0
     OR position('payment.is_revenue = true' IN v_definition) = 0
     OR position('source_system = ''restaurant_pos''' IN v_definition) = 0
     OR position('photo_objet_brand_id' IN v_definition) = 0
     OR pg_catalog.has_function_privilege('anon', v_export, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', v_export, 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_EXPORT_ALL_STORES_VERIFY_FAILED';
  END IF;
END;
$verification$;

COMMIT;
