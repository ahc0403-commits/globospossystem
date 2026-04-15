BEGIN;

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
  v_serial_no text;
  v_wt05_payload jsonb;
BEGIN
  SELECT *
  INTO v_actor
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

  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.restaurant_id IS DISTINCT FROM p_store_id THEN
    RAISE EXCEPTION 'ORDER_STORE_MISMATCH';
  END IF;

  SELECT *
  INTO v_job
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

  v_store_code := COALESCE(v_shop.provider_shop_code, v_te.tax_code);
  v_store_name := COALESCE(v_shop.shop_name, v_restaurant.name, 'GLOBOSVN');

  SELECT (t->>'serial_no')
  INTO v_serial_no
  FROM jsonb_array_elements(COALESCE(v_shop.templates, '[]'::jsonb)) AS t
  WHERE (t->>'status_code') = '1'
  LIMIT 1;

  v_serial_no := COALESCE(v_serial_no, 'C26MTT');
  v_ref_id := v_job.ref_id;

  SELECT jsonb_build_object(
    'seller', jsonb_build_object(
      'tax_code', v_te.tax_code,
      'store_code', v_store_code,
      'store_name', v_store_name
    ),
    'invoices', jsonb_build_array(
      (v_job.send_order_payload) ||
      jsonb_build_object(
        'ref_id', v_ref_id,
        'invoice_type', '0',
        'form_no', '1',
        'serial_no', v_serial_no,
        'cqt_code', '',
        'buyer_comp_name', COALESCE(p_buyer_name, ''),
        'buyer_tax_code', COALESCE(p_buyer_tax_code, ''),
        'buyer_address', COALESCE(p_buyer_address, ''),
        'buyer_tel', COALESCE(p_buyer_tel, ''),
        'buyer_email', p_receiver_email,
        'buyer_email_cc', COALESCE(p_receiver_email_cc, ''),
        'tot_amount', (
          SELECT COALESCE(SUM((oi.unit_price * oi.quantity)::numeric), 0)
          FROM order_items oi
          WHERE oi.order_id = p_order_id AND oi.status <> 'cancelled'
        ),
        'tot_vat_amount', (
          SELECT COALESCE(SUM(oi.vat_amount::numeric), 0)
          FROM order_items oi
          WHERE oi.order_id = p_order_id AND oi.status <> 'cancelled'
        ),
        'tot_dc_amount', 0,
        'tot_pay_amount', (
          SELECT COALESCE(SUM(oi.paying_amount_inc_tax::numeric), 0)
          FROM order_items oi
          WHERE oi.order_id = p_order_id AND oi.status <> 'cancelled'
        )
      )
    )
  ) INTO v_wt05_payload;

  UPDATE einvoice_jobs
  SET
    redinvoice_requested = TRUE,
    request_einvoice_payload = v_wt05_payload,
    request_einvoice_retry_count = 0,
    request_einvoice_next_retry_at = NULL,
    updated_at = now()
  WHERE id = v_job.id;

  IF p_buyer_tax_code IS NOT NULL AND p_buyer_tax_code <> '' THEN
    INSERT INTO b2b_buyer_cache (
      store_id, buyer_tax_code, tax_id, tax_company_name,
      tax_address, receiver_email, receiver_email_cc,
      first_used_at, last_used_at, use_count, tax_entity_id
    ) VALUES (
      p_store_id,
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
      'receiver_email', p_receiver_email
    )
  );

  RETURN jsonb_build_object('ok', true, 'job_id', v_job.id, 'ref_id', v_ref_id);
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
  v_tax_entity_id uuid;
  v_row b2b_buyer_cache%ROWTYPE;
BEGIN
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

  SELECT tax_entity_id
  INTO v_tax_entity_id
  FROM restaurants
  WHERE id = p_store_id;

  SELECT *
  INTO v_row
  FROM b2b_buyer_cache
  WHERE buyer_tax_code = p_tax_code
    AND (
      store_id = p_store_id
      OR (v_tax_entity_id IS NOT NULL AND tax_entity_id = v_tax_entity_id)
    )
  ORDER BY (store_id = p_store_id) DESC, last_used_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'tax_company_name', v_row.tax_company_name,
    'tax_address', v_row.tax_address,
    'receiver_email', v_row.receiver_email,
    'receiver_email_cc', v_row.receiver_email_cc
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_staff_account(
  p_user_id uuid,
  p_restaurant_id uuid,
  p_full_name text DEFAULT NULL,
  p_is_active boolean DEFAULT NULL,
  p_extra_permissions text[] DEFAULT NULL
)
RETURNS public.users AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_target public.users%ROWTYPE;
  v_updated public.users%ROWTYPE;
  v_target_brand_id uuid;
  v_full_name text := NULLIF(btrim(COALESCE(p_full_name, '')), '');
  v_changed_fields text[] := ARRAY[]::text[];
  v_old_values jsonb := '{}'::jsonb;
  v_new_values jsonb := '{}'::jsonb;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  IF p_user_id IS NULL OR p_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_INVALID';
  END IF;

  SELECT brand_id
  INTO v_target_brand_id
  FROM public.restaurants
  WHERE id = p_restaurant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_INVALID';
  END IF;

  IF v_actor.role IN ('admin', 'store_admin')
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_restaurant_id
     ) THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  IF v_actor.role = 'brand_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_brands(auth.uid()) b(brand_id)
       WHERE b.brand_id = v_target_brand_id
     ) THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_target
  FROM public.users
  WHERE id = p_user_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_NOT_FOUND';
  END IF;

  IF v_actor.role IN ('admin', 'store_admin')
     AND v_target.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin', 'photo_objet_master') THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  IF v_actor.role = 'brand_admin'
     AND v_target.role IN ('brand_admin', 'super_admin', 'photo_objet_master') THEN
    RAISE EXCEPTION 'STAFF_ACCOUNT_UPDATE_FORBIDDEN';
  END IF;

  IF p_full_name IS NOT NULL THEN
    IF v_full_name IS NULL THEN
      RAISE EXCEPTION 'USER_FULL_NAME_REQUIRED';
    END IF;
    IF v_full_name IS DISTINCT FROM v_target.full_name THEN
      v_changed_fields := array_append(v_changed_fields, 'full_name');
      v_old_values := v_old_values || jsonb_build_object('full_name', v_target.full_name);
      v_new_values := v_new_values || jsonb_build_object('full_name', v_full_name);
    END IF;
  ELSE
    v_full_name := v_target.full_name;
  END IF;

  IF p_is_active IS NOT NULL AND p_is_active IS DISTINCT FROM v_target.is_active THEN
    v_changed_fields := array_append(v_changed_fields, 'is_active');
    v_old_values := v_old_values || jsonb_build_object('is_active', v_target.is_active);
    v_new_values := v_new_values || jsonb_build_object('is_active', p_is_active);
  END IF;

  IF p_extra_permissions IS NOT NULL
     AND COALESCE(p_extra_permissions, ARRAY[]::text[]) IS DISTINCT FROM COALESCE(v_target.extra_permissions, ARRAY[]::text[]) THEN
    v_changed_fields := array_append(v_changed_fields, 'extra_permissions');
    v_old_values := v_old_values || jsonb_build_object('extra_permissions', COALESCE(v_target.extra_permissions, ARRAY[]::text[]));
    v_new_values := v_new_values || jsonb_build_object('extra_permissions', COALESCE(p_extra_permissions, ARRAY[]::text[]));
  END IF;

  UPDATE public.users
  SET full_name = v_full_name,
      is_active = COALESCE(p_is_active, v_target.is_active),
      extra_permissions = CASE
        WHEN p_extra_permissions IS NULL THEN v_target.extra_permissions
        ELSE COALESCE(p_extra_permissions, ARRAY[]::text[])
      END
  WHERE id = v_target.id
  RETURNING * INTO v_updated;

  IF array_length(v_changed_fields, 1) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_staff_account',
      'users',
      v_updated.id,
      jsonb_build_object(
        'restaurant_id', v_updated.restaurant_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values
      )
    );

    PERFORM public.refresh_user_claims(v_target.auth_id);
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.admin_retry_einvoice_job(
  p_job_id uuid,
  p_store_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_job einvoice_jobs%ROWTYPE;
  v_job_store_id uuid;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'EINVOICE_RETRY_FORBIDDEN';
  END IF;

  IF p_job_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'EINVOICE_RETRY_INVALID';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_job
  FROM public.einvoice_jobs ej
  WHERE ej.id = p_job_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EINVOICE_JOB_NOT_FOUND';
  END IF;

  SELECT o.restaurant_id
  INTO v_job_store_id
  FROM public.orders o
  WHERE o.id = v_job.order_id
  LIMIT 1;

  IF v_job_store_id IS DISTINCT FROM p_store_id THEN
    RAISE EXCEPTION 'EINVOICE_JOB_STORE_MISMATCH';
  END IF;

  IF v_job.status NOT IN ('failed_terminal', 'stale') THEN
    RAISE EXCEPTION 'EINVOICE_JOB_NOT_RETRYABLE';
  END IF;

  IF COALESCE(v_job.error_classification, '') = 'duplicate_resolved' THEN
    RAISE EXCEPTION 'EINVOICE_JOB_DUPLICATE_RESOLVED';
  END IF;

  UPDATE public.einvoice_jobs
  SET status = 'pending',
      dispatch_attempts = 0,
      error_classification = NULL,
      error_message = NULL,
      request_einvoice_retry_count = 0,
      request_einvoice_next_retry_at = NULL,
      updated_at = now()
  WHERE id = v_job.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_retry_einvoice_job',
    'einvoice_jobs',
    v_job.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'previous_status', v_job.status,
      'ref_id', v_job.ref_id
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'job_id', v_job.id,
    'ref_id', v_job.ref_id,
    'status', 'pending'
  );
END;
$$;

COMMIT;
