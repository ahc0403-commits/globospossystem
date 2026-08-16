BEGIN;

-- production-gate: self-verifying

-- A Restaurant report is one MISA invoice per paid POS order. Photo Objet and
-- external delivery settlements are outside this customer-receipt workbook.
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
    JOIN public.restaurant_cutoff_policies policy
      ON policy.restaurant_id = payment.restaurant_id
     AND policy.is_enabled = true
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
  'Super-admin unified MISA workbook source for all finalized Restaurant POS receipts; excludes Photo Objet and external settlements.';

-- MISA does not require email for invoice reporting. Keep the legacy wide RPC
-- for compatibility and expose a minimal wrapper used by current POS forms.
CREATE OR REPLACE FUNCTION public.upsert_red_invoice_intake_minimal(
  p_order_id uuid,
  p_store_id uuid,
  p_source text DEFAULT 'cashier',
  p_status text DEFAULT 'awaiting_information',
  p_buyer_tax_code text DEFAULT NULL,
  p_buyer_legal_name text DEFAULT NULL,
  p_buyer_address text DEFAULT NULL,
  p_source_note text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_payload jsonb;
  v_intake public.red_invoice_intakes%ROWTYPE;
  v_complete_buyer boolean := p_status IN ('ready', 'exported', 'completed');
  v_effective_status text := p_status;
BEGIN
  IF v_complete_buyer AND (
    COALESCE(btrim(p_buyer_tax_code), '') = ''
    OR COALESCE(btrim(p_buyer_legal_name), '') = ''
    OR COALESCE(btrim(p_buyer_address), '') = ''
  ) THEN
    RAISE EXCEPTION 'RED_INVOICE_BUYER_INFORMATION_INCOMPLETE';
  END IF;

  v_payload := public.upsert_red_invoice_intake(
    p_order_id,
    p_store_id,
    p_source,
    CASE WHEN v_complete_buyer THEN 'awaiting_information' ELSE p_status END,
    p_buyer_tax_code,
    NULL,
    p_buyer_legal_name,
    NULL,
    p_buyer_address,
    NULL,
    NULL,
    NULL,
    NULL,
    p_source_note
  );

  IF NOT v_complete_buyer THEN
    RETURN v_payload;
  END IF;

  IF v_payload->>'status' = 'manual_review' THEN
    v_effective_status := 'manual_review';
  END IF;

  UPDATE public.red_invoice_intakes
  SET status = v_effective_status,
      buyer_tax_code = NULLIF(btrim(p_buyer_tax_code), ''),
      buyer_legal_name = NULLIF(btrim(p_buyer_legal_name), ''),
      buyer_address = NULLIF(btrim(p_buyer_address), ''),
      buyer_unit_code = NULL,
      buyer_full_name = NULL,
      buyer_email = NULL,
      buyer_email_cc = NULL,
      buyer_phone = NULL,
      buyer_id = NULL,
      ready_at = CASE
        WHEN v_effective_status = 'ready' THEN COALESCE(ready_at, now())
        ELSE ready_at
      END,
      updated_at = now()
  WHERE order_id = p_order_id AND store_id = p_store_id
  RETURNING * INTO v_intake;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RED_INVOICE_INTAKE_NOT_FOUND';
  END IF;

  UPDATE public.meinvoice_jobs
  SET buyer_kind = 'registered',
      buyer_snapshot = jsonb_build_object(
        'tax_code', btrim(p_buyer_tax_code),
        'tin_cic_household_head_id', btrim(p_buyer_tax_code),
        'unit_name', btrim(p_buyer_legal_name),
        'address', btrim(p_buyer_address),
        'source', 'red_invoice_intake'
      ),
      status = CASE
        WHEN status IN ('sent_to_misa', 'sent_to_tax_authority', 'valid_invoice')
          THEN 'manual_action_required'
        WHEN status IN ('pending', 'pending_manual_config')
          THEN 'dispatch_paused'
        ELSE status
      END,
      manual_action_type = CASE
        WHEN status IN ('sent_to_misa', 'sent_to_tax_authority', 'valid_invoice')
          THEN 'buyer_info_after_issue'
        ELSE manual_action_type
      END,
      updated_at = now()
  WHERE id = v_intake.meinvoice_job_id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'upsert_red_invoice_intake_minimal',
    'red_invoice_intakes', v_intake.id,
    jsonb_build_object(
      'order_id', p_order_id,
      'store_id', p_store_id,
      'status', v_effective_status,
      'required_fields', jsonb_build_array(
        'buyer_tax_code', 'buyer_legal_name', 'buyer_address'
      )
    )
  );

  RETURN to_jsonb(v_intake);
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_red_invoice_intake_minimal(
  uuid, uuid, text, text, text, text, text, text
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_red_invoice_intake_minimal(
  uuid, uuid, text, text, text, text, text, text
) TO authenticated;

DO $$
DECLARE
  v_export regprocedure :=
    'public.get_restaurant_daily_sales_export(date)'::regprocedure;
  v_minimal regprocedure :=
    'public.upsert_red_invoice_intake_minimal(uuid,uuid,text,text,text,text,text,text)'::regprocedure;
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(v_export::oid) INTO v_definition;
  IF position('photo_objet_brand_id' IN v_definition) = 0
     OR position('source_system = ''restaurant_pos''' IN v_definition) = 0
     OR position('line_items' IN v_definition) = 0
     OR pg_catalog.has_function_privilege('anon', v_export, 'EXECUTE')
     OR NOT pg_catalog.has_function_privilege(
       'authenticated', v_export, 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'UNIFIED_RESTAURANT_MISA_EXPORT_VERIFY_FAILED';
  END IF;

  SELECT pg_get_functiondef(v_minimal::oid) INTO v_definition;
  IF position('p_buyer_email' IN v_definition) > 0
     OR position('p_buyer_tax_code' IN v_definition) = 0
     OR position('p_buyer_legal_name' IN v_definition) = 0
     OR position('p_buyer_address' IN v_definition) = 0
     OR pg_catalog.has_function_privilege('anon', v_minimal, 'EXECUTE') THEN
    RAISE EXCEPTION 'MINIMAL_RED_INVOICE_FIELDS_VERIFY_FAILED';
  END IF;
END;
$$;

COMMIT;
