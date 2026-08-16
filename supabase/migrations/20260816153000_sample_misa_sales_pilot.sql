BEGIN;

-- production-gate: self-verifying

-- One-time pilot fixture requested for BunsikClub SAMPLE on 2026-08-15.
-- It leaves the first receipt general and marks the other two as Red Invoice
-- ready with unmistakable non-production buyer data. No MISA dispatch occurs.
DO $guard$
DECLARE
  v_store_id constant uuid := '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid;
  v_order_ids constant uuid[] := ARRAY[
    'dee5df02-b080-4a4a-a6b7-eefebdc5c4ba'::uuid,
    'b80806b5-b496-472a-b250-ea83b90209b0'::uuid,
    'a584f119-8bfd-4e79-842e-4e19574d1b3f'::uuid
  ];
  v_order_count integer;
  v_gross_amount numeric(18,2);
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurants restaurant
    WHERE restaurant.id = v_store_id
      AND restaurant.name = 'BunsikClub SAMPLE'
      AND restaurant.is_active = true
      AND restaurant.tax_entity_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'SAMPLE_MISA_PILOT_STORE_NOT_READY';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurant_daily_sales_finalizations finalization
    WHERE finalization.business_date = DATE '2026-08-15'
      AND finalization.status = 'finalized'
  ) THEN
    RAISE EXCEPTION 'SAMPLE_MISA_PILOT_DATE_NOT_FINALIZED';
  END IF;

  SELECT count(DISTINCT orders.id),
         round(sum(COALESCE(payment.amount_portion, payment.amount)), 2)
  INTO v_order_count, v_gross_amount
  FROM public.orders orders
  JOIN public.payments payment
    ON payment.order_id = orders.id
   AND payment.restaurant_id = v_store_id
   AND payment.is_revenue = true
  WHERE orders.id = ANY(v_order_ids)
    AND orders.restaurant_id = v_store_id
    AND orders.status = 'completed'
    AND payment.created_at >= TIMESTAMPTZ '2026-08-15 00:00:00+07'
    AND payment.created_at < TIMESTAMPTZ '2026-08-16 00:00:00+07';

  IF v_order_count <> 3 OR v_gross_amount <> 1152360.00 THEN
    RAISE EXCEPTION
      'SAMPLE_MISA_PILOT_SALES_CHANGED orders=% gross=%',
      v_order_count,
      v_gross_amount;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.red_invoice_intakes intake
    WHERE intake.order_id = ANY(v_order_ids)
  ) THEN
    RAISE EXCEPTION 'SAMPLE_MISA_PILOT_ALREADY_CONFIGURED';
  END IF;

  IF (
    SELECT count(*)
    FROM public.meinvoice_jobs job
    WHERE job.order_id = ANY(v_order_ids)
      AND job.store_id = v_store_id
      AND job.source_system = 'restaurant_pos'
      AND job.status = 'pending_manual_config'
      AND jsonb_typeof(job.line_items_snapshot) = 'array'
      AND jsonb_array_length(job.line_items_snapshot) > 0
  ) <> 3 THEN
    RAISE EXCEPTION 'SAMPLE_MISA_PILOT_JOBS_CHANGED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.meinvoice_jobs job
    CROSS JOIN LATERAL (
      SELECT round(COALESCE(sum(
        COALESCE((line->>'total_amount_ex_tax')::numeric, 0)
        + COALESCE((line->>'vat_amount')::numeric, 0)
      ), 0), 2) AS gross_amount
      FROM jsonb_array_elements(job.line_items_snapshot) line
    ) line_total
    CROSS JOIN LATERAL (
      SELECT round(sum(COALESCE(payment.amount_portion, payment.amount)), 2)
        AS gross_amount
      FROM public.payments payment
      WHERE payment.order_id = job.order_id
        AND payment.restaurant_id = v_store_id
        AND payment.is_revenue = true
    ) payment_total
    WHERE job.order_id = ANY(v_order_ids)
      AND abs(line_total.gross_amount - payment_total.gross_amount) > 1
  ) THEN
    RAISE EXCEPTION 'SAMPLE_MISA_PILOT_LINE_TOTAL_MISMATCH';
  END IF;
END;
$guard$;

WITH pilot_red_orders (
  order_id,
  buyer_tax_code,
  buyer_legal_name,
  buyer_address
) AS (
  VALUES
    (
      'b80806b5-b496-472a-b250-ea83b90209b0'::uuid,
      '0000000000'::text,
      'DU LIEU THU HOA DON DO 01 - KHONG PHAT HANH'::text,
      'DIA CHI MAU 01 - KHONG PHAT HANH'::text
    ),
    (
      'a584f119-8bfd-4e79-842e-4e19574d1b3f'::uuid,
      '0000000001'::text,
      'DU LIEU THU HOA DON DO 02 - KHONG PHAT HANH'::text,
      'DIA CHI MAU 02 - KHONG PHAT HANH'::text
    )
),
receipt_data AS (
  SELECT
    payment.order_id,
    array_agg(payment.id::text ORDER BY payment.created_at, payment.id)
      AS receipt_ids,
    max(payment.created_at) AS sale_at,
    round(sum(COALESCE(payment.amount_portion, payment.amount)), 2)
      AS gross_amount,
    array_agg(DISTINCT payment.method ORDER BY payment.method)
      AS payment_methods
  FROM public.payments payment
  JOIN pilot_red_orders pilot ON pilot.order_id = payment.order_id
  WHERE payment.restaurant_id =
      '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
    AND payment.is_revenue = true
  GROUP BY payment.order_id
)
INSERT INTO public.red_invoice_intakes (
  order_id,
  store_id,
  tax_entity_id,
  meinvoice_job_id,
  receipt_ids,
  sale_at,
  gross_amount,
  payment_method,
  line_items_snapshot,
  source,
  status,
  buyer_tax_code,
  buyer_legal_name,
  buyer_address,
  source_note,
  ready_at
)
SELECT
  pilot.order_id,
  job.store_id,
  job.tax_entity_id,
  job.id,
  receipt.receipt_ids,
  receipt.sale_at,
  receipt.gross_amount,
  COALESCE(
    NULLIF(btrim(job.payment_method_snapshot), ''),
    public.meinvoice_payment_method_label(
      job.tax_entity_id,
      receipt.payment_methods
    )
  ),
  job.line_items_snapshot,
  'other',
  'ready',
  pilot.buyer_tax_code,
  pilot.buyer_legal_name,
  pilot.buyer_address,
  'BunsikClub SAMPLE MISA pilot 2026-08-15; test data only; do not issue',
  now()
FROM pilot_red_orders pilot
JOIN receipt_data receipt ON receipt.order_id = pilot.order_id
JOIN public.meinvoice_jobs job
  ON job.order_id = pilot.order_id
 AND job.store_id = '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
 AND job.source_system = 'restaurant_pos';

UPDATE public.meinvoice_jobs job
SET
  buyer_kind = 'registered',
  buyer_snapshot = jsonb_build_object(
    'tax_code', pilot.buyer_tax_code,
    'tin_cic_household_head_id', pilot.buyer_tax_code,
    'unit_name', pilot.buyer_legal_name,
    'address', pilot.buyer_address,
    'source', 'sample_misa_sales_pilot',
    'test_data_only', true
  ),
  status = 'dispatch_paused',
  updated_at = now()
FROM (
  VALUES
    (
      'b80806b5-b496-472a-b250-ea83b90209b0'::uuid,
      '0000000000'::text,
      'DU LIEU THU HOA DON DO 01 - KHONG PHAT HANH'::text,
      'DIA CHI MAU 01 - KHONG PHAT HANH'::text
    ),
    (
      'a584f119-8bfd-4e79-842e-4e19574d1b3f'::uuid,
      '0000000001'::text,
      'DU LIEU THU HOA DON DO 02 - KHONG PHAT HANH'::text,
      'DIA CHI MAU 02 - KHONG PHAT HANH'::text
    )
) AS pilot(order_id, buyer_tax_code, buyer_legal_name, buyer_address)
WHERE job.order_id = pilot.order_id
  AND job.store_id = '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
  AND job.source_system = 'restaurant_pos'
  AND job.status = 'pending_manual_config';

INSERT INTO public.audit_logs (
  actor_id,
  action,
  entity_type,
  entity_id,
  details
)
SELECT
  NULL,
  'seed_sample_misa_sales_pilot',
  'red_invoice_intakes',
  intake.id,
  jsonb_build_object(
    'migration', '20260816153000',
    'store_id', intake.store_id,
    'business_date', '2026-08-15',
    'order_id', intake.order_id,
    'status', intake.status,
    'test_data_only', true,
    'misa_dispatch', 'paused'
  )
FROM public.red_invoice_intakes intake
WHERE intake.order_id = ANY(ARRAY[
  'b80806b5-b496-472a-b250-ea83b90209b0'::uuid,
  'a584f119-8bfd-4e79-842e-4e19574d1b3f'::uuid
]);

DO $verification$
DECLARE
  v_store_id constant uuid := '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid;
  v_general_order_id constant uuid :=
    'dee5df02-b080-4a4a-a6b7-eefebdc5c4ba'::uuid;
  v_red_order_ids constant uuid[] := ARRAY[
    'b80806b5-b496-472a-b250-ea83b90209b0'::uuid,
    'a584f119-8bfd-4e79-842e-4e19574d1b3f'::uuid
  ];
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.red_invoice_intakes
    WHERE order_id = v_general_order_id
  ) THEN
    RAISE EXCEPTION 'SAMPLE_MISA_PILOT_GENERAL_RECEIPT_CHANGED';
  END IF;

  IF (
    SELECT count(*)
    FROM public.red_invoice_intakes intake
    WHERE intake.order_id = ANY(v_red_order_ids)
      AND intake.store_id = v_store_id
      AND intake.status = 'ready'
      AND COALESCE(btrim(intake.buyer_tax_code), '') <> ''
      AND COALESCE(btrim(intake.buyer_legal_name), '') <> ''
      AND COALESCE(btrim(intake.buyer_address), '') <> ''
      AND intake.buyer_email IS NULL
      AND intake.buyer_phone IS NULL
      AND intake.buyer_id IS NULL
  ) <> 2 THEN
    RAISE EXCEPTION 'SAMPLE_MISA_PILOT_RED_RECEIPT_VERIFY_FAILED';
  END IF;

  IF (
    SELECT count(*)
    FROM public.meinvoice_jobs job
    WHERE job.order_id = ANY(v_red_order_ids)
      AND job.store_id = v_store_id
      AND job.source_system = 'restaurant_pos'
      AND job.buyer_kind = 'registered'
      AND job.status = 'dispatch_paused'
      AND job.buyer_snapshot->>'test_data_only' = 'true'
  ) <> 2 THEN
    RAISE EXCEPTION 'SAMPLE_MISA_PILOT_DISPATCH_GUARD_VERIFY_FAILED';
  END IF;
END;
$verification$;

COMMIT;
