BEGIN;

-- production-gate: self-verifying

-- The Restaurant finalization remains an independent 22:20 audit control.
-- Reporting is available from 22:00 HCM once sale-producing mutations have
-- already been closed by the 21:45 database cutoff. A missing finalization row
-- must not hide otherwise reportable Restaurant or Photo sales.
CREATE OR REPLACE FUNCTION public.get_restaurant_daily_sales_exports_by_tax_entity(
  p_business_date date
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_finalization public.restaurant_daily_sales_finalizations%ROWTYPE;
  v_has_finalization boolean := false;
  v_entities jsonb := '[]'::jsonb;
  v_start timestamptz;
  v_end timestamptz;
  v_hcm_now timestamp :=
    statement_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_report_ready_at timestamptz;
  v_report_status text;
  v_photo_objet_brand_id constant uuid :=
    '77000000-0000-0000-0000-000000000001'::uuid;
  v_sample_store_id constant uuid :=
    '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid;
  v_sample_entity_id constant uuid :=
    '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid;
BEGIN
  IF p_business_date IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_EXPORT_DATE_REQUIRED';
  END IF;
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_EXPORT_FORBIDDEN';
  END IF;

  v_report_ready_at := (p_business_date + TIME '22:00:00')
    AT TIME ZONE 'Asia/Ho_Chi_Minh';

  IF p_business_date > v_hcm_now::date
     OR (
       p_business_date = v_hcm_now::date
       AND v_hcm_now::time < TIME '22:00:00'
     ) THEN
    RETURN jsonb_build_object(
      'business_date', p_business_date,
      'status', 'pending',
      'report_ready_at', v_report_ready_at,
      'entities', '[]'::jsonb
    );
  END IF;

  SELECT * INTO v_finalization
  FROM public.restaurant_daily_sales_finalizations finalization
  WHERE finalization.business_date = p_business_date;
  v_has_finalization := FOUND;

  IF v_has_finalization AND v_finalization.status <> 'finalized' THEN
    RETURN jsonb_build_object(
      'business_date', p_business_date,
      'status', v_finalization.status,
      'report_ready_at', v_report_ready_at,
      'entities', '[]'::jsonb
    );
  END IF;

  v_report_status := CASE
    WHEN v_has_finalization THEN 'finalized'
    ELSE 'ready'
  END;
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
      seller.id AS tax_entity_id,
      seller.tax_code AS seller_tax_code,
      seller.name AS seller_legal_name,
      seller.id = v_sample_entity_id AS is_sample_entity,
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
          seller.id,
          paid.payment_methods
        )
      ) AS payment_method,
      intake.id IS NOT NULL AND intake.status <> 'cancelled'
        AS is_red_invoice,
      COALESCE(intake.status, '') AS red_invoice_status,
      COALESCE(intake.buyer_tax_code, '') AS buyer_tax_code,
      COALESCE(intake.buyer_legal_name, '') AS buyer_legal_name,
      COALESCE(intake.buyer_address, '') AS buyer_address,
      COALESCE(intake.buyer_email, '') AS buyer_email,
      COALESCE(intake.buyer_phone, '') AS buyer_phone,
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
      SELECT
        candidate.tax_entity_id,
        candidate.payment_method_snapshot,
        candidate.line_items_snapshot
      FROM public.meinvoice_jobs candidate
      WHERE candidate.order_id = paid.order_id
        AND candidate.source_system = 'restaurant_pos'
      ORDER BY candidate.created_at DESC, candidate.id DESC
      LIMIT 1
    ) job ON true
    LEFT JOIN LATERAL (
      SELECT history.tax_entity_id
      FROM public.store_tax_entity_history history
      WHERE history.store_id = paid.store_id
        AND history.effective_from <= paid.sold_at
        AND (
          history.effective_to IS NULL
          OR paid.sold_at < history.effective_to
        )
      ORDER BY history.effective_from DESC, history.created_at DESC
      LIMIT 1
    ) historical_entity ON true
    JOIN public.tax_entity seller
      ON seller.id = CASE
        WHEN paid.store_id = v_sample_store_id THEN restaurant.tax_entity_id
        ELSE COALESCE(
          job.tax_entity_id,
          historical_entity.tax_entity_id,
          restaurant.tax_entity_id
        )
      END
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
  ),
  entity_rollups AS (
    SELECT
      rows.tax_entity_id,
      rows.seller_tax_code,
      rows.seller_legal_name,
      rows.is_sample_entity,
      count(DISTINCT rows.store_id)::integer AS store_count,
      count(*)::integer AS receipt_count,
      round(COALESCE(sum(rows.gross_sales), 0), 2) AS gross_sales,
      jsonb_agg(
        to_jsonb(rows)
        ORDER BY rows.sold_at, rows.receipt_id
      ) AS receipts
    FROM report_rows rows
    GROUP BY
      rows.tax_entity_id,
      rows.seller_tax_code,
      rows.seller_legal_name,
      rows.is_sample_entity
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'business_date', p_business_date,
      'status', v_report_status,
      'report_ready_at', v_report_ready_at,
      'tax_entity_id', rollup.tax_entity_id,
      'seller_tax_code', rollup.seller_tax_code,
      'seller_legal_name', rollup.seller_legal_name,
      'is_sample_entity', rollup.is_sample_entity,
      'store_count', rollup.store_count,
      'receipt_count', rollup.receipt_count,
      'gross_sales', rollup.gross_sales,
      'finalized_at', CASE
        WHEN v_has_finalization THEN v_finalization.finalized_at
        ELSE NULL
      END,
      'receipts', rollup.receipts
    ) ORDER BY
      rollup.is_sample_entity,
      rollup.seller_tax_code,
      rollup.tax_entity_id
  ), '[]'::jsonb)
  INTO v_entities
  FROM entity_rollups rollup;

  RETURN jsonb_build_object(
    'business_date', p_business_date,
    'status', v_report_status,
    'report_ready_at', v_report_ready_at,
    'finalized_at', CASE
      WHEN v_has_finalization THEN v_finalization.finalized_at
      ELSE NULL
    END,
    'entity_count', jsonb_array_length(v_entities),
    'entities', v_entities
  );
END;
$$;

REVOKE ALL ON FUNCTION
  public.get_restaurant_daily_sales_exports_by_tax_entity(date)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION
  public.get_restaurant_daily_sales_exports_by_tax_entity(date)
  TO authenticated;

COMMENT ON FUNCTION
  public.get_restaurant_daily_sales_exports_by_tax_entity(date) IS
  'Super-admin MISA export grouped by seller entity. Today opens at 22:00 HCM independently of the 22:20 audit finalization; confirmed integrity failures still fail closed.';

CREATE OR REPLACE FUNCTION public.get_restaurant_daily_sales_export(
  p_business_date date
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_payload jsonb;
  v_entities jsonb;
BEGIN
  v_payload := public.get_restaurant_daily_sales_exports_by_tax_entity(
    p_business_date
  );
  IF v_payload->>'status' NOT IN ('ready', 'finalized') THEN
    RETURN jsonb_build_object(
      'business_date', v_payload->>'business_date',
      'status', v_payload->>'status',
      'report_ready_at', v_payload->'report_ready_at',
      'receipts', '[]'::jsonb
    );
  END IF;

  v_entities := v_payload->'entities';
  IF jsonb_array_length(v_entities) > 1 THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_EXPORT_TAX_ENTITY_REQUIRED';
  END IF;
  IF jsonb_array_length(v_entities) = 0 THEN
    RETURN jsonb_build_object(
      'business_date', v_payload->>'business_date',
      'status', v_payload->>'status',
      'store_count', 0,
      'receipt_count', 0,
      'gross_sales', 0,
      'report_ready_at', v_payload->'report_ready_at',
      'finalized_at', v_payload->'finalized_at',
      'receipts', '[]'::jsonb
    );
  END IF;
  RETURN v_entities->0;
END;
$$;

REVOKE ALL ON FUNCTION public.get_restaurant_daily_sales_export(date)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_restaurant_daily_sales_export(date)
  TO authenticated;

COMMENT ON FUNCTION public.get_restaurant_daily_sales_export(date) IS
  'Legacy single-entity MISA export with the same 22:00 HCM availability contract as the grouped endpoint.';

DO $verification$
DECLARE
  v_grouped regprocedure :=
    'public.get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure;
  v_legacy regprocedure :=
    'public.get_restaurant_daily_sales_export(date)'::regprocedure;
  v_grouped_definition text;
  v_legacy_definition text;
BEGIN
  SELECT pg_get_functiondef(v_grouped::oid) INTO v_grouped_definition;
  IF position('22:00:00' IN v_grouped_definition) = 0
     OR position('v_report_status' IN v_grouped_definition) = 0
     OR position('ready' IN v_grouped_definition) = 0
     OR position('report_ready_at' IN v_grouped_definition) = 0
     OR position('v_finalization.status' IN v_grouped_definition) = 0
     OR position('finalized' IN v_grouped_definition) = 0
     OR pg_catalog.has_function_privilege('anon', v_grouped, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', v_grouped, 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_REPORT_2200_GROUPED_VERIFY_FAILED';
  END IF;

  SELECT pg_get_functiondef(v_legacy::oid) INTO v_legacy_definition;
  IF position('ready' IN v_legacy_definition) = 0
     OR position('finalized' IN v_legacy_definition) = 0
     OR pg_catalog.has_function_privilege('anon', v_legacy, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', v_legacy, 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_REPORT_2200_LEGACY_VERIFY_FAILED';
  END IF;
END;
$verification$;

COMMIT;
