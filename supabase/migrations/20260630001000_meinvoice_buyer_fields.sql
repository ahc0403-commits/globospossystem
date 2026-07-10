-- MISA meInvoice buyer-field completion for restaurant POS.
-- Matches the MISA cash-register invoice form fields captured at checkout.

BEGIN;

ALTER TABLE public.b2b_buyer_cache
  ADD COLUMN IF NOT EXISTS buyer_unit_code text,
  ADD COLUMN IF NOT EXISTS buyer_full_name text,
  ADD COLUMN IF NOT EXISTS buyer_id text,
  ADD COLUMN IF NOT EXISTS buyer_phone text;

COMMENT ON COLUMN public.b2b_buyer_cache.buyer_unit_code IS
  'MISA Unit code entered at restaurant POS for red/VAT invoice requests.';
COMMENT ON COLUMN public.b2b_buyer_cache.buyer_full_name IS
  'MISA Buyer Full Name entered at restaurant POS.';
COMMENT ON COLUMN public.b2b_buyer_cache.buyer_id IS
  'MISA Buyer ID entered at restaurant POS.';
COMMENT ON COLUMN public.b2b_buyer_cache.buyer_phone IS
  'MISA buyer phone number entered at restaurant POS.';

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
  p_buyer_tel text DEFAULT NULL,
  p_unit_code text DEFAULT NULL,
  p_unit_name text DEFAULT NULL,
  p_buyer_full_name text DEFAULT NULL,
  p_buyer_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_job public.meinvoice_jobs%ROWTYPE;
  v_tax_entity_id uuid;
  v_tax_code text;
  v_manual_action_required boolean := false;
  v_unit_name text;
  v_photo_objet_brand_id constant uuid := '77000000-0000-0000-0000-000000000001';
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = true
  LIMIT 1;

  IF NOT FOUND
     OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_REQUIRED';
  END IF;

  IF NOT public.is_super_admin()
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

  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.restaurants r
    WHERE r.id = p_store_id
      AND r.brand_id = v_photo_objet_brand_id
  ) THEN
    RAISE EXCEPTION 'RED_INVOICE_DISABLED_FOR_PHOTO_OBJET';
  END IF;

  SELECT r.tax_entity_id, te.tax_code
  INTO v_tax_entity_id, v_tax_code
  FROM public.restaurants r
  JOIN public.tax_entity te ON te.id = r.tax_entity_id
  WHERE r.id = p_store_id;

  IF v_tax_entity_id IS NULL OR v_tax_code = 'PLACEHOLDER_DEV_000' THEN
    RAISE EXCEPTION 'TAX_ENTITY_NOT_READY';
  END IF;

  v_unit_name := COALESCE(NULLIF(btrim(p_unit_name), ''), NULLIF(btrim(p_buyer_name), ''), '');

  SELECT *
  INTO v_job
  FROM public.meinvoice_jobs
  WHERE order_id = p_order_id
  LIMIT 1;

  IF NOT FOUND THEN
    INSERT INTO public.meinvoice_jobs (
      order_id,
      store_id,
      tax_entity_id,
      buyer_kind,
      buyer_snapshot,
      payment_method_snapshot,
      status
    )
    VALUES (
      p_order_id,
      p_store_id,
      v_tax_entity_id,
      'anonymous',
      jsonb_build_object('customer_name', 'Người mua không lấy hóa đơn'),
      public.meinvoice_payment_method_label(v_tax_entity_id, ARRAY[]::text[]),
      'pending_manual_config'
    )
    RETURNING * INTO v_job;
  END IF;

  v_manual_action_required :=
    v_job.status IN ('sent_to_misa', 'sent_to_tax_authority', 'valid_invoice');

  UPDATE public.meinvoice_jobs
  SET
    buyer_kind = 'registered',
    buyer_snapshot = jsonb_build_object(
      'tin_cic_household_head_id', COALESCE(p_buyer_tax_code, ''),
      'unit_code', COALESCE(p_unit_code, ''),
      'unit_name', v_unit_name,
      'address', COALESCE(p_buyer_address, ''),
      'buyer_full_name', COALESCE(p_buyer_full_name, ''),
      'email', p_receiver_email,
      'email_cc', COALESCE(p_receiver_email_cc, ''),
      'phone', COALESCE(p_buyer_tel, ''),
      'buyer_id', COALESCE(p_buyer_id, ''),
      'source', 'restaurant_pos'
    ),
    status = CASE
      WHEN v_manual_action_required THEN 'manual_action_required'
      ELSE status
    END,
    manual_action_type = CASE
      WHEN v_manual_action_required THEN 'buyer_info_after_issue'
      ELSE manual_action_type
    END,
    manual_action_note = CASE
      WHEN v_manual_action_required THEN
        'Buyer VAT information was entered after the invoice had already been sent; handle replace/adjust/incorrect-invoice notice manually in MISA.'
      ELSE manual_action_note
    END,
    updated_at = now()
  WHERE id = v_job.id
  RETURNING * INTO v_job;

  IF p_buyer_tax_code IS NOT NULL AND p_buyer_tax_code <> '' THEN
    INSERT INTO public.b2b_buyer_cache (
      store_id,
      buyer_tax_code,
      buyer_unit_code,
      tax_company_name,
      tax_address,
      tax_buyer_name,
      buyer_full_name,
      buyer_id,
      buyer_phone,
      receiver_email,
      receiver_email_cc,
      first_used_at,
      last_used_at,
      use_count,
      tax_entity_id
    )
    VALUES (
      p_store_id,
      p_buyer_tax_code,
      NULLIF(btrim(COALESCE(p_unit_code, '')), ''),
      v_unit_name,
      COALESCE(p_buyer_address, ''),
      COALESCE(p_buyer_full_name, ''),
      COALESCE(p_buyer_full_name, ''),
      COALESCE(p_buyer_id, ''),
      COALESCE(p_buyer_tel, ''),
      p_receiver_email,
      p_receiver_email_cc,
      now(),
      now(),
      1,
      v_tax_entity_id
    )
    ON CONFLICT (store_id, buyer_tax_code) DO UPDATE SET
      buyer_unit_code = EXCLUDED.buyer_unit_code,
      tax_company_name = EXCLUDED.tax_company_name,
      tax_address = EXCLUDED.tax_address,
      tax_buyer_name = EXCLUDED.tax_buyer_name,
      buyer_full_name = EXCLUDED.buyer_full_name,
      buyer_id = EXCLUDED.buyer_id,
      buyer_phone = EXCLUDED.buyer_phone,
      receiver_email = EXCLUDED.receiver_email,
      receiver_email_cc = EXCLUDED.receiver_email_cc,
      last_used_at = now(),
      use_count = public.b2b_buyer_cache.use_count + 1,
      tax_entity_id = EXCLUDED.tax_entity_id;
  END IF;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'request_red_invoice',
    'meinvoice_jobs',
    v_job.id,
    jsonb_build_object(
      'provider', 'meinvoice',
      'order_id', p_order_id,
      'store_id', p_store_id,
      'buyer_tax_code', p_buyer_tax_code,
      'unit_code', p_unit_code,
      'unit_name', v_unit_name,
      'buyer_full_name', p_buyer_full_name,
      'receiver_email', p_receiver_email,
      'manual_action_required', v_manual_action_required
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', v_job.id,
    'provider', 'meinvoice',
    'manual_action_required', v_manual_action_required
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.lookup_b2b_buyer(
  p_store_id uuid,
  p_tax_code text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_row b2b_buyer_cache%ROWTYPE;
BEGIN
  SELECT *
  INTO v_row
  FROM b2b_buyer_cache
  WHERE buyer_tax_code = p_tax_code
  ORDER BY (store_id = p_store_id) DESC, last_used_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'buyer_tax_code', v_row.buyer_tax_code,
    'buyer_unit_code', v_row.buyer_unit_code,
    'tax_company_name', v_row.tax_company_name,
    'tax_address', v_row.tax_address,
    'tax_buyer_name', COALESCE(v_row.tax_buyer_name, v_row.buyer_full_name),
    'buyer_full_name', COALESCE(v_row.buyer_full_name, v_row.tax_buyer_name),
    'buyer_id', v_row.buyer_id,
    'buyer_phone', v_row.buyer_phone,
    'receiver_email', v_row.receiver_email,
    'receiver_email_cc', v_row.receiver_email_cc
  );
END;
$$;

COMMIT;
