BEGIN;

-- production-gate: self-verifying

-- Print station identities follow the same store-code naming contract as
-- other device accounts (for example, BT -> bt_print@globos.world).
CREATE OR REPLACE FUNCTION public.admin_configure_store_workforce(
  p_store_id uuid,
  p_short_code text,
  p_management_model text,
  p_brand_manager_slots integer,
  p_account_templates jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_brand_id uuid;
  v_existing_short_code text;
  v_item jsonb;
  v_count integer := 0;
BEGIN
  v_actor := public.require_workforce_manager(p_store_id);
  SELECT brand_id, short_code INTO v_brand_id, v_existing_short_code
  FROM public.restaurants WHERE id = p_store_id;
  IF v_brand_id IS NULL THEN RAISE EXCEPTION 'STORE_BRAND_REQUIRED'; END IF;
  IF upper(btrim(p_short_code)) !~ '^[A-Z0-9]{2,6}$' THEN
    RAISE EXCEPTION 'STORE_SHORT_CODE_INVALID';
  END IF;
  IF p_management_model NOT IN ('brand_centralized', 'store_managed') THEN
    RAISE EXCEPTION 'MANAGEMENT_MODEL_INVALID';
  END IF;
  IF p_brand_manager_slots NOT BETWEEN 1 AND 20 THEN
    RAISE EXCEPTION 'BRAND_MANAGER_SLOTS_INVALID';
  END IF;
  IF jsonb_typeof(p_account_templates) <> 'array'
     OR jsonb_array_length(p_account_templates) = 0 THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATES_REQUIRED';
  END IF;
  IF jsonb_array_length(p_account_templates) > 50 THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATE_LIMIT';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_account_templates) item(value)
    GROUP BY lower(value->>'account_code') HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'ACCOUNT_TEMPLATE_DUPLICATE_CODE';
  END IF;
  IF (
    SELECT count(*) FROM jsonb_array_elements(p_account_templates) item(value)
    WHERE value->>'account_type' = 'brand_manager'
  ) NOT IN (0, p_brand_manager_slots) THEN
    RAISE EXCEPTION 'BRAND_MANAGER_TEMPLATE_COUNT_INVALID';
  END IF;
  IF v_existing_short_code IS NOT NULL
     AND v_existing_short_code <> upper(btrim(p_short_code))
     AND (
       EXISTS (SELECT 1 FROM public.store_employees WHERE store_id = p_store_id)
       OR EXISTS (
         SELECT 1 FROM public.store_fixed_account_requirements
         WHERE store_id = p_store_id AND provisioned_user_id IS NOT NULL
       )
     ) THEN
    RAISE EXCEPTION 'STORE_SHORT_CODE_IMMUTABLE_AFTER_USE';
  END IF;

  UPDATE public.restaurants SET short_code = upper(btrim(p_short_code))
  WHERE id = p_store_id;
  UPDATE public.brands SET
    management_model = p_management_model,
    brand_manager_slots = p_brand_manager_slots
  WHERE id = v_brand_id;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_account_templates) LOOP
    IF COALESCE(v_item->>'account_code', '') !~ '^[a-z][a-z0-9_]{1,31}$'
       OR COALESCE(v_item->>'scope', '') NOT IN ('brand', 'store')
       OR COALESCE(v_item->>'account_type', '') NOT IN (
         'brand_manager', 'store_manager', 'device_pos', 'device_tablet',
         'device_kitchen', 'device_print_station', 'device_customer_display',
         'store_operator'
       )
       OR COALESCE(v_item->>'role', '') NOT IN (
         'brand_admin', 'store_admin', 'cashier', 'kitchen', 'print_station',
         'customer_display', 'photo_objet_master',
         'photo_objet_store_operator'
       )
       OR NULLIF(btrim(COALESCE(v_item->>'display_name', '')), '') IS NULL THEN
      RAISE EXCEPTION 'ACCOUNT_TEMPLATE_INVALID';
    END IF;
    IF (v_item->>'account_type') = 'brand_manager'
       AND v_actor.role <> 'super_admin' THEN
      RAISE EXCEPTION 'BRAND_MANAGER_TEMPLATE_FORBIDDEN';
    END IF;
    IF (v_item->>'account_type') = 'store_manager'
       AND v_actor.role NOT IN ('super_admin', 'brand_admin') THEN
      RAISE EXCEPTION 'STORE_MANAGER_TEMPLATE_FORBIDDEN';
    END IF;
    IF p_management_model = 'brand_centralized'
       AND (v_item->>'account_type') = 'store_manager' THEN
      RAISE EXCEPTION 'CENTRALIZED_STORE_MANAGER_FORBIDDEN';
    END IF;
    IF (v_item->>'account_type') IN (
      'device_pos', 'device_tablet', 'device_kitchen',
      'device_print_station', 'device_customer_display', 'store_operator'
    ) AND (v_item->>'account_code') NOT LIKE
      lower(upper(btrim(p_short_code))) || '\_%' ESCAPE '\' THEN
      RAISE EXCEPTION 'STORE_ACCOUNT_CODE_PREFIX_INVALID';
    END IF;
    INSERT INTO public.store_fixed_account_requirements(
      store_id, account_code, account_type, role, display_name, scope
    ) VALUES (
      p_store_id, v_item->>'account_code', v_item->>'account_type',
      v_item->>'role', btrim(v_item->>'display_name'), v_item->>'scope'
    ) ON CONFLICT (store_id, account_code) DO UPDATE SET
      account_type = EXCLUDED.account_type,
      role = EXCLUDED.role,
      display_name = EXCLUDED.display_name,
      scope = EXCLUDED.scope,
      is_active = true,
      updated_at = now();
    v_count := v_count + 1;
  END LOOP;
  UPDATE public.store_fixed_account_requirements q SET
    is_active = false,
    updated_at = now()
  WHERE q.store_id = p_store_id
    AND q.provisioned_user_id IS NULL
    AND q.is_active = true
    AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_account_templates) item(value)
      WHERE lower(value->>'account_code') = lower(q.account_code)
    );
  RETURN jsonb_build_object(
    'configured', true,
    'store_id', p_store_id,
    'short_code', upper(btrim(p_short_code)),
    'management_model', p_management_model,
    'template_count', v_count
  );
END;
$$;

DO $account$
DECLARE
  v_store_id constant uuid := '8bc9eef5-dcd5-46b1-b931-23f77132322c';
  v_existing public.store_fixed_account_requirements%ROWTYPE;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.restaurants
    WHERE id = v_store_id AND is_active = true
  ) THEN
    RAISE EXCEPTION 'PRINT_STATION_ACCOUNT_STORE_UNAVAILABLE';
  END IF;

  SELECT * INTO v_existing
  FROM public.store_fixed_account_requirements
  WHERE store_id = v_store_id AND account_code = 'bt_print';

  IF FOUND THEN
    IF v_existing.account_type IS DISTINCT FROM 'device_print_station'
       OR v_existing.role IS DISTINCT FROM 'print_station'
       OR v_existing.scope IS DISTINCT FROM 'store' THEN
      RAISE EXCEPTION 'PRINT_STATION_ACCOUNT_REQUIREMENT_CONFLICT';
    END IF;
  ELSE
    INSERT INTO public.store_fixed_account_requirements (
      store_id, account_code, account_type, role, display_name, scope, is_active
    ) VALUES (
      v_store_id, 'bt_print', 'device_print_station',
      'print_station', 'BT Print Station', 'store', true
    );
  END IF;

  -- The earlier generic `print` requirement was never a safe multi-store
  -- identity. Retire it only while it is still unprovisioned; a live identity
  -- requires an explicit credential handover instead of an automatic rename.
  UPDATE public.store_fixed_account_requirements
  SET is_active = false, updated_at = now()
  WHERE store_id = v_store_id
    AND account_code = 'print'
    AND provisioned_user_id IS NULL;
END;
$account$;

DO $verify$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.admin_configure_store_workforce(uuid,text,text,integer,jsonb)'
      ::regprocedure
  ) INTO v_definition;

  IF position('device_print_station' IN v_definition) = 0
     OR position('STORE_ACCOUNT_CODE_PREFIX_INVALID' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'STORE_PRINT_ACCOUNT_CONFIG_VERIFICATION_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.store_fixed_account_requirements
    WHERE store_id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
      AND account_code = 'bt_print'
      AND account_type = 'device_print_station'
      AND role = 'print_station'
      AND scope = 'store'
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'BT_PRINT_ACCOUNT_REQUIREMENT_VERIFICATION_FAILED';
  END IF;
END;
$verify$;

COMMIT;
