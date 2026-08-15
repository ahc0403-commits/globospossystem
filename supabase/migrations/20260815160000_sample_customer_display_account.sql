BEGIN;

-- Register the dedicated customer-facing display login for BunsikClub SAMPLE.
-- Auth provisioning and its initial password remain in the approved
-- provision-fixed-pos-account flow; this migration never stores credentials.
DO $sample_customer_display$
DECLARE
  v_store_id uuid;
  v_store_count integer;
  v_existing public.store_fixed_account_requirements%ROWTYPE;
BEGIN
  SELECT count(*), (array_agg(id))[1]
  INTO v_store_count, v_store_id
  FROM public.restaurants
  WHERE upper(btrim(short_code)) = 'SP'
    AND is_active = true;

  IF v_store_count <> 1 OR v_store_id IS NULL THEN
    RAISE EXCEPTION 'SAMPLE_CUSTOMER_DISPLAY_STORE_CARDINALITY_INVALID';
  END IF;

  SELECT * INTO v_existing
  FROM public.store_fixed_account_requirements
  WHERE store_id = v_store_id
    AND account_code = 'sp_customer';

  IF FOUND THEN
    IF v_existing.account_type IS DISTINCT FROM 'device_customer_display'
       OR v_existing.role IS DISTINCT FROM 'customer_display'
       OR v_existing.scope IS DISTINCT FROM 'store' THEN
      RAISE EXCEPTION 'SAMPLE_CUSTOMER_DISPLAY_ACCOUNT_REQUIREMENT_CONFLICT';
    END IF;

    UPDATE public.store_fixed_account_requirements
    SET display_name = 'SP Customer Display',
        is_active = true,
        updated_at = now()
    WHERE id = v_existing.id;
  ELSE
    INSERT INTO public.store_fixed_account_requirements (
      store_id, account_code, account_type, role, display_name, scope, is_active
    ) VALUES (
      v_store_id, 'sp_customer', 'device_customer_display',
      'customer_display', 'SP Customer Display', 'store', true
    );
  END IF;
END;
$sample_customer_display$;

-- production-gate: self-verifying
DO $verify$
DECLARE
  v_store_id uuid;
BEGIN
  SELECT id INTO v_store_id
  FROM public.restaurants
  WHERE upper(btrim(short_code)) = 'SP'
    AND is_active = true;

  IF v_store_id IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.store_fixed_account_requirements
    WHERE store_id = v_store_id
      AND account_code = 'sp_customer'
      AND account_type = 'device_customer_display'
      AND role = 'customer_display'
      AND scope = 'store'
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'SAMPLE_CUSTOMER_DISPLAY_ACCOUNT_VERIFICATION_FAILED';
  END IF;
END;
$verify$;

COMMIT;
