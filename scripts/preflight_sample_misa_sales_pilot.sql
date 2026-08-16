DO $preflight$
DECLARE
  v_store_id constant uuid := '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid;
  v_general_order_id constant uuid :=
    'dee5df02-b080-4a4a-a6b7-eefebdc5c4ba'::uuid;
  v_red_order_ids constant uuid[] := ARRAY[
    'b80806b5-b496-472a-b250-ea83b90209b0'::uuid,
    'a584f119-8bfd-4e79-842e-4e19574d1b3f'::uuid
  ];
  v_order_ids constant uuid[] := ARRAY[
    v_general_order_id,
    v_red_order_ids[1],
    v_red_order_ids[2]
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
$preflight$;
