BEGIN;

DROP FUNCTION IF EXISTS public.request_red_invoice(
  uuid,
  uuid,
  text,
  text,
  text,
  text,
  text,
  text
);

CREATE OR REPLACE FUNCTION public.request_red_invoice(
  p_order_id uuid,
  p_store_id uuid,
  p_buyer_tax_code text,
  p_buyer_name text,
  p_buyer_address text,
  p_receiver_email text,
  p_receiver_email_cc text DEFAULT NULL,
  p_buyer_tel text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_job einvoice_jobs%ROWTYPE;
  v_shop einvoice_shop%ROWTYPE;
  v_te tax_entity%ROWTYPE;
  v_restaurant restaurants%ROWTYPE;
  v_ref_id text;
  v_store_code text;
  v_store_name text;
  v_order_date text;
  v_request_payload jsonb;
  v_photo_objet_brand_id constant uuid := '77000000-0000-0000-0000-000000000001';
BEGIN
  SELECT * INTO v_actor
  FROM users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_REQUIRED';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  IF p_receiver_email IS NULL OR trim(p_receiver_email) = '' THEN
    RAISE EXCEPTION 'EMAIL_REQUIRED';
  END IF;

  SELECT * INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  SELECT * INTO v_job
  FROM einvoice_jobs
  WHERE order_id = p_order_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'JOB_NOT_FOUND';
  END IF;

  IF v_job.status IN ('failed_terminal') THEN
    RAISE EXCEPTION 'JOB_FAILED';
  END IF;

  SELECT * INTO v_shop FROM einvoice_shop WHERE id = v_job.einvoice_shop_id;
  SELECT * INTO v_te FROM tax_entity WHERE id = v_job.tax_entity_id;
  SELECT * INTO v_restaurant FROM restaurants WHERE id = p_store_id;

  IF v_restaurant.brand_id = v_photo_objet_brand_id THEN
    RAISE EXCEPTION 'RED_INVOICE_DISABLED_FOR_PHOTO_OBJET';
  END IF;

  v_store_code := COALESCE(v_shop.provider_shop_code, v_te.tax_code);
  v_store_name := COALESCE(v_shop.shop_name, v_restaurant.name, 'GLOBOSVN');
  v_ref_id := v_job.ref_id;
  v_order_date := to_char(v_order.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh', 'YYYYMMDD');

  SELECT jsonb_build_object(
    'bills', jsonb_build_array(
      jsonb_build_object(
        'ref_id', v_ref_id,
        'tax_id', COALESCE(p_buyer_tax_code, ''),
        'tax_company_name', COALESCE(p_buyer_name, ''),
        'tax_address', COALESCE(p_buyer_address, ''),
        'tax_buyer_name', '',
        'receiver_email', p_receiver_email,
        'receiver_email_cc', COALESCE(p_receiver_email_cc, ''),
        'order_date', v_order_date,
        'store_code', v_store_code,
        'store_name', v_store_name,
        'pos_number', COALESCE(v_job.send_order_payload->>'pos_no', '001'),
        'order_id', COALESCE(v_job.send_order_payload->>'bill_no', v_ref_id)
      )
    )
  ) INTO v_request_payload;

  UPDATE einvoice_jobs
  SET
    redinvoice_requested = TRUE,
    request_einvoice_payload = v_request_payload,
    request_einvoice_retry_count = 0,
    request_einvoice_next_retry_at = NULL,
    error_classification = NULL,
    error_message = NULL,
    updated_at = now()
  WHERE id = v_job.id;

  IF p_buyer_tax_code IS NOT NULL AND p_buyer_tax_code <> '' THEN
    INSERT INTO b2b_buyer_cache (
      store_id, buyer_tax_code, tax_company_name,
      tax_address, receiver_email, receiver_email_cc,
      first_used_at, last_used_at, use_count, tax_entity_id
    ) VALUES (
      p_store_id,
      p_buyer_tax_code,
      COALESCE(p_buyer_name, ''),
      COALESCE(p_buyer_address, ''),
      p_receiver_email,
      p_receiver_email_cc,
      now(), now(), 1,
      v_te.id
    )
    ON CONFLICT (store_id, buyer_tax_code) DO UPDATE SET
      tax_company_name = EXCLUDED.tax_company_name,
      tax_address = EXCLUDED.tax_address,
      receiver_email = EXCLUDED.receiver_email,
      receiver_email_cc = EXCLUDED.receiver_email_cc,
      last_used_at = now(),
      use_count = b2b_buyer_cache.use_count + 1;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'request_red_invoice',
    'einvoice_jobs',
    v_job.id,
    jsonb_build_object(
      'order_id', p_order_id,
      'store_id', p_store_id,
      'buyer_tax_code', p_buyer_tax_code,
      'receiver_email', p_receiver_email,
      'payload_type', 'requestEinvoiceInfo'
    )
  );

  RETURN jsonb_build_object('ok', true, 'job_id', v_job.id, 'ref_id', v_ref_id);
END;
$$;

COMMIT;
