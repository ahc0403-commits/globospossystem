-- Stage 2 Step 1 — request_red_invoice RPC
-- Called from POS app after cashier selects "Yes" to red invoice modal
-- 1. Validates the einvoice_job exists for this order
-- 2. Builds WT05 /pos/invoices-issue payload
-- 3. Updates einvoice_job: redinvoice_requested=true, request_einvoice_payload
-- 4. Upserts b2b_buyer_cache for future autocomplete

CREATE OR REPLACE FUNCTION public.request_red_invoice(
  p_order_id         uuid,
  p_buyer_tax_code   text,
  p_buyer_name       text,        -- company name
  p_buyer_address    text,
  p_receiver_email   text,        -- required
  p_receiver_email_cc text DEFAULT NULL,
  p_buyer_tel        text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor        users%ROWTYPE;
  v_job          einvoice_jobs%ROWTYPE;
  v_shop         einvoice_shop%ROWTYPE;
  v_te           tax_entity%ROWTYPE;
  v_restaurant   restaurants%ROWTYPE;
  v_ref_id       text;
  v_store_code   text;
  v_store_name   text;
  v_serial_no    text;
  v_wt05_payload jsonb;
BEGIN
  -- Auth: cashier or higher
  SELECT * INTO v_actor FROM users
  WHERE auth_id = auth.uid() AND is_active = TRUE LIMIT 1;
  IF NOT FOUND OR v_actor.role NOT IN ('cashier','admin','super_admin') THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  -- Validate email
  IF p_receiver_email IS NULL OR trim(p_receiver_email) = '' THEN
    RAISE EXCEPTION 'EMAIL_REQUIRED';
  END IF;

  -- Find the einvoice_job for this order
  SELECT * INTO v_job FROM einvoice_jobs
  WHERE order_id = p_order_id
  ORDER BY created_at DESC LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'JOB_NOT_FOUND';
  END IF;
  IF v_job.status IN ('failed_terminal') THEN
    RAISE EXCEPTION 'JOB_FAILED';
  END IF;

  -- Load shop + tax_entity + restaurant for payload
  SELECT * INTO v_shop FROM einvoice_shop WHERE id = v_job.einvoice_shop_id;
  SELECT * INTO v_te FROM tax_entity WHERE id = v_job.tax_entity_id;
  SELECT * INTO v_restaurant FROM restaurants WHERE tax_entity_id = v_job.tax_entity_id LIMIT 1;

  v_store_code := COALESCE(v_shop.provider_shop_code, v_te.tax_code);
  v_store_name := COALESCE(v_shop.shop_name, v_restaurant.name, 'GLOBOSVN');

  -- Pick active template serial_no from shop templates JSONB
  SELECT (t->>'serial_no')
  INTO v_serial_no
  FROM jsonb_array_elements(COALESCE(v_shop.templates, '[]'::jsonb)) AS t
  WHERE (t->>'status_code') = '1'
  LIMIT 1;
  -- Fallback if no template found (shouldn't happen in production)
  v_serial_no := COALESCE(v_serial_no, 'C26MTT');

  v_ref_id := v_job.ref_id;

  -- Build WT05 /pos/invoices-issue complete body
  -- seller{} at top level, invoices[] for invoice details
  SELECT jsonb_build_object(
    'seller', jsonb_build_object(
      'tax_code',   v_te.tax_code,
      'store_code', v_store_code,
      'store_name', v_store_name
    ),
    'invoices', jsonb_build_array(
      (v_job.send_order_payload) ||
      jsonb_build_object(
        'ref_id',          v_ref_id,
        'invoice_type',    '0',
        'form_no',         '1',
        'serial_no',       v_serial_no,
        'cqt_code',        '',
        'buyer_comp_name', COALESCE(p_buyer_name, ''),
        'buyer_tax_code',  COALESCE(p_buyer_tax_code, ''),
        'buyer_address',   COALESCE(p_buyer_address, ''),
        'buyer_tel',       COALESCE(p_buyer_tel, ''),
        'buyer_email',     p_receiver_email,
        'buyer_email_cc',  COALESCE(p_receiver_email_cc, ''),
        'tot_amount',      (
          SELECT COALESCE(SUM((oi.unit_price * oi.quantity)::numeric), 0)
          FROM order_items oi
          WHERE oi.order_id = p_order_id AND oi.status <> 'cancelled'
        ),
        'tot_vat_amount',  (
          SELECT COALESCE(SUM(oi.vat_amount::numeric), 0)
          FROM order_items oi
          WHERE oi.order_id = p_order_id AND oi.status <> 'cancelled'
        ),
        'tot_dc_amount',   0,
        'tot_pay_amount',  (
          SELECT COALESCE(SUM(oi.paying_amount_inc_tax::numeric), 0)
          FROM order_items oi
          WHERE oi.order_id = p_order_id AND oi.status <> 'cancelled'
        )
      )
    )
  ) INTO v_wt05_payload;

  -- Update einvoice_job
  UPDATE einvoice_jobs SET
    redinvoice_requested      = TRUE,
    request_einvoice_payload  = v_wt05_payload,
    request_einvoice_retry_count     = 0,
    request_einvoice_next_retry_at   = NULL,
    updated_at                = now()
  WHERE id = v_job.id;

  -- Upsert b2b_buyer_cache (for autocomplete next time)
  IF p_buyer_tax_code IS NOT NULL AND p_buyer_tax_code <> '' AND v_actor.restaurant_id IS NOT NULL THEN
    INSERT INTO b2b_buyer_cache (
      store_id, buyer_tax_code, tax_id, tax_company_name,
      tax_address, receiver_email, receiver_email_cc,
      first_used_at, last_used_at, use_count, tax_entity_id
    ) VALUES (
      v_actor.restaurant_id,
      p_buyer_tax_code,
      p_buyer_tax_code,
      COALESCE(p_buyer_name, ''),
      COALESCE(p_buyer_address, ''),
      p_receiver_email,
      p_receiver_email_cc,
      now(), now(), 1,
      v_te.id
    )
    ON CONFLICT (store_id, buyer_tax_code) DO UPDATE SET
      tax_company_name   = EXCLUDED.tax_company_name,
      tax_address        = EXCLUDED.tax_address,
      receiver_email     = EXCLUDED.receiver_email,
      receiver_email_cc  = EXCLUDED.receiver_email_cc,
      last_used_at       = now(),
      use_count          = b2b_buyer_cache.use_count + 1;
  END IF;

  -- Audit
  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (auth.uid(), 'request_red_invoice', 'einvoice_jobs', v_job.id,
    jsonb_build_object('order_id', p_order_id, 'buyer_tax_code', p_buyer_tax_code,
                       'receiver_email', p_receiver_email));

  RETURN jsonb_build_object('ok', true, 'job_id', v_job.id, 'ref_id', v_ref_id);
END;
$$;

-- Also add a helper to look up b2b_buyer_cache for autocomplete
CREATE OR REPLACE FUNCTION public.lookup_b2b_buyer(
  p_store_id     uuid,
  p_tax_code     text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_row b2b_buyer_cache%ROWTYPE;
BEGIN
  -- Look in current store first, then same tax_entity
  SELECT * INTO v_row FROM b2b_buyer_cache
  WHERE buyer_tax_code = p_tax_code
  ORDER BY (store_id = p_store_id) DESC, last_used_at DESC
  LIMIT 1;

  IF NOT FOUND THEN RETURN NULL; END IF;

  RETURN jsonb_build_object(
    'tax_company_name', v_row.tax_company_name,
    'tax_address',      v_row.tax_address,
    'receiver_email',   v_row.receiver_email,
    'receiver_email_cc',v_row.receiver_email_cc
  );
END;
$$;;
