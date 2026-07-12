-- Admin configuration RPC for MISA meInvoice seller setup.
-- Stores non-secret seller settings only. Does not enable live dispatch.

BEGIN;

CREATE OR REPLACE FUNCTION public.admin_upsert_meinvoice_tax_entity_config(
  p_tax_entity_id uuid,
  p_app_id text DEFAULT NULL,
  p_invoice_series text DEFAULT NULL,
  p_integration_status text DEFAULT NULL,
  p_auth_base_url text DEFAULT NULL,
  p_api_base_url text DEFAULT NULL,
  p_payment_method_cash text DEFAULT NULL,
  p_payment_method_card text DEFAULT NULL,
  p_payment_method_pay text DEFAULT NULL,
  p_payment_method_mixed text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_tax_entity public.tax_entity%ROWTYPE;
  v_current public.meinvoice_tax_entity_config%ROWTYPE;
  v_app_id text;
  v_invoice_series text;
  v_integration_status text;
  v_auth_base_url text;
  v_api_base_url text;
  v_payment_method_cash text;
  v_payment_method_card text;
  v_payment_method_pay text;
  v_payment_method_mixed text;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'MEINVOICE_CONFIG_FORBIDDEN';
  END IF;

  IF p_tax_entity_id IS NULL THEN
    RAISE EXCEPTION 'MEINVOICE_CONFIG_INVALID';
  END IF;

  SELECT *
  INTO v_tax_entity
  FROM public.tax_entity
  WHERE id = p_tax_entity_id
    AND einvoice_provider = 'meinvoice'
    AND tax_code <> 'PLACEHOLDER_DEV_000'
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MEINVOICE_TAX_ENTITY_NOT_FOUND';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.restaurants r
       JOIN public.user_accessible_stores(auth.uid()) s(store_id)
         ON s.store_id = r.id
       WHERE r.tax_entity_id = p_tax_entity_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_current
  FROM public.meinvoice_tax_entity_config
  WHERE tax_entity_id = p_tax_entity_id
  LIMIT 1;

  v_app_id := COALESCE(
    NULLIF(trim(p_app_id), ''),
    NULLIF(trim(v_current.app_id), '')
  );
  v_invoice_series := COALESCE(
    NULLIF(trim(p_invoice_series), ''),
    NULLIF(trim(v_current.invoice_series), '')
  );
  v_integration_status := COALESCE(
    NULLIF(trim(p_integration_status), ''),
    NULLIF(trim(v_current.integration_status), ''),
    'configured'
  );

  IF v_integration_status NOT IN (
    'needs_vendor_activation',
    'configured',
    'active',
    'paused'
  ) THEN
    RAISE EXCEPTION 'MEINVOICE_CONFIG_STATUS_INVALID';
  END IF;

  IF v_integration_status = 'active'
     AND (v_app_id IS NULL OR v_invoice_series IS NULL) THEN
    RAISE EXCEPTION 'MEINVOICE_ACTIVE_CONFIG_INCOMPLETE';
  END IF;

  v_auth_base_url := regexp_replace(
    COALESCE(
      NULLIF(trim(p_auth_base_url), ''),
      NULLIF(trim(v_current.auth_base_url), ''),
      'https://api.meinvoice.vn/api/integration'
    ),
    '/+$',
    ''
  );
  v_api_base_url := regexp_replace(
    COALESCE(
      NULLIF(trim(p_api_base_url), ''),
      NULLIF(trim(v_current.api_base_url), ''),
      'https://api.meinvoice.vn/api/integration/invoice'
    ),
    '/+$',
    ''
  );
  v_payment_method_cash := COALESCE(
    NULLIF(trim(p_payment_method_cash), ''),
    NULLIF(trim(v_current.payment_method_cash), ''),
    'Tiền mặt'
  );
  v_payment_method_card := COALESCE(
    NULLIF(trim(p_payment_method_card), ''),
    NULLIF(trim(v_current.payment_method_card), ''),
    'Thẻ quốc tế'
  );
  v_payment_method_pay := COALESCE(
    NULLIF(trim(p_payment_method_pay), ''),
    NULLIF(trim(v_current.payment_method_pay), ''),
    'Ví điện tử/QR'
  );
  v_payment_method_mixed := COALESCE(
    NULLIF(trim(p_payment_method_mixed), ''),
    NULLIF(trim(v_current.payment_method_mixed), ''),
    'Tiền mặt/Thẻ/Ví điện tử'
  );

  INSERT INTO public.meinvoice_tax_entity_config (
    tax_entity_id,
    auth_base_url,
    api_base_url,
    app_id,
    invoice_series,
    payment_method_cash,
    payment_method_card,
    payment_method_pay,
    payment_method_mixed,
    integration_status,
    last_verified_at,
    updated_at
  )
  VALUES (
    p_tax_entity_id,
    v_auth_base_url,
    v_api_base_url,
    v_app_id,
    v_invoice_series,
    v_payment_method_cash,
    v_payment_method_card,
    v_payment_method_pay,
    v_payment_method_mixed,
    v_integration_status,
    CASE WHEN v_integration_status = 'active' THEN now() ELSE NULL END,
    now()
  )
  ON CONFLICT (tax_entity_id) DO UPDATE
  SET auth_base_url = EXCLUDED.auth_base_url,
      api_base_url = EXCLUDED.api_base_url,
      app_id = EXCLUDED.app_id,
      invoice_series = EXCLUDED.invoice_series,
      payment_method_cash = EXCLUDED.payment_method_cash,
      payment_method_card = EXCLUDED.payment_method_card,
      payment_method_pay = EXCLUDED.payment_method_pay,
      payment_method_mixed = EXCLUDED.payment_method_mixed,
      integration_status = EXCLUDED.integration_status,
      last_verified_at = CASE
        WHEN EXCLUDED.integration_status = 'active' THEN now()
        ELSE public.meinvoice_tax_entity_config.last_verified_at
      END,
      updated_at = now();

  DELETE FROM public.meinvoice_token_cache
  WHERE tax_entity_id = p_tax_entity_id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_upsert_meinvoice_tax_entity_config',
    'meinvoice_tax_entity_config',
    p_tax_entity_id,
    jsonb_build_object(
      'tax_code', v_tax_entity.tax_code,
      'integration_status', v_integration_status,
      'app_id_configured', v_app_id IS NOT NULL,
      'invoice_series_configured', v_invoice_series IS NOT NULL,
      'token_cache_cleared', true
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'tax_entity_id', p_tax_entity_id,
    'provider', 'meinvoice',
    'integration_status', v_integration_status,
    'app_id_configured', v_app_id IS NOT NULL,
    'invoice_series_configured', v_invoice_series IS NOT NULL,
    'dispatch_gate_changed', false
  );
END;
$$;

COMMENT ON FUNCTION public.admin_upsert_meinvoice_tax_entity_config(
  uuid,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text
) IS
  'Upserts non-secret MISA seller settings and clears cached runtime tokens. Does not enable live dispatch.';

REVOKE ALL ON FUNCTION public.admin_upsert_meinvoice_tax_entity_config(
  uuid,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_upsert_meinvoice_tax_entity_config(
  uuid,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text
) TO authenticated;

COMMIT;
