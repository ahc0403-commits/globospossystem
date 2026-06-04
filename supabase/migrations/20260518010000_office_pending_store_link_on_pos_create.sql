BEGIN;

-- New POS stores must have an Office store identity before sales start so
-- opening investment and setup expenses remain store-scoped from day one.

ALTER TABLE ops.stores
  ADD COLUMN IF NOT EXISTS pos_store_id uuid;

ALTER TABLE ops.stores
  DROP CONSTRAINT IF EXISTS ops_stores_pos_store_fk;

ALTER TABLE ops.stores
  ADD CONSTRAINT ops_stores_pos_store_fk
  FOREIGN KEY (pos_store_id)
  REFERENCES public.restaurants(id)
  ON DELETE SET NULL
  DEFERRABLE INITIALLY DEFERRED;

CREATE UNIQUE INDEX IF NOT EXISTS idx_ops_stores_pos_store_id
  ON ops.stores(pos_store_id)
  WHERE pos_store_id IS NOT NULL;

COMMENT ON COLUMN ops.stores.pos_store_id IS
  'POS public.restaurants.id linked when the store opens in POS. Office store id stays stable for pre-opening expenses and investment records.';

CREATE OR REPLACE FUNCTION public.ensure_office_brand_for_pos_brand(
  p_brand_id uuid
) RETURNS uuid AS $$
DECLARE
  v_brand public.brands%ROWTYPE;
BEGIN
  IF p_brand_id IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_BRAND_REQUIRED';
  END IF;

  SELECT *
  INTO v_brand
  FROM public.brands
  WHERE id = p_brand_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTAURANT_BRAND_NOT_FOUND';
  END IF;

  INSERT INTO ops.brands (
    id,
    name,
    status,
    created_at
  )
  VALUES (
    v_brand.id,
    v_brand.name,
    'active'::core.account_status,
    now()
  )
  ON CONFLICT (id) DO UPDATE
  SET name = EXCLUDED.name;

  RETURN v_brand.id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, ops, core, auth;

CREATE OR REPLACE FUNCTION public.link_office_pending_store_for_pos_store(
  p_pos_store_id uuid,
  p_name text,
  p_brand_id uuid,
  p_address text DEFAULT NULL,
  p_office_store_id uuid DEFAULT NULL
) RETURNS uuid AS $$
DECLARE
  v_office_brand_id uuid;
  v_office_store_id uuid;
  v_name text := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_address text := NULLIF(btrim(COALESCE(p_address, '')), '');
BEGIN
  IF p_pos_store_id IS NULL THEN
    RAISE EXCEPTION 'POS_STORE_ID_REQUIRED';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_NAME_REQUIRED';
  END IF;

  v_office_brand_id := public.ensure_office_brand_for_pos_brand(p_brand_id);

  IF p_office_store_id IS NOT NULL THEN
    UPDATE ops.stores
    SET pos_store_id = p_pos_store_id,
        name = v_name,
        address = COALESCE(v_address, address)
    WHERE id = p_office_store_id
      AND brand_id = v_office_brand_id
      AND status = 'pending'::core.account_status
      AND (pos_store_id IS NULL OR pos_store_id = p_pos_store_id)
    RETURNING id INTO v_office_store_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'OFFICE_PENDING_STORE_NOT_FOUND';
    END IF;

    RETURN v_office_store_id;
  END IF;

  SELECT s.id
  INTO v_office_store_id
  FROM ops.stores s
  WHERE s.brand_id = v_office_brand_id
    AND s.status = 'pending'::core.account_status
    AND s.pos_store_id IS NULL
    AND lower(btrim(s.name)) = lower(v_name)
  ORDER BY
    CASE
      WHEN NULLIF(btrim(COALESCE(s.address, '')), '') IS NOT DISTINCT FROM v_address THEN 0
      ELSE 1
    END,
    s.created_at ASC
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    UPDATE ops.stores
    SET pos_store_id = p_pos_store_id,
        address = CASE
          WHEN NULLIF(btrim(COALESCE(address, '')), '') IS NULL AND v_address IS NOT NULL
            THEN v_address
          ELSE address
        END
    WHERE id = v_office_store_id;

    RETURN v_office_store_id;
  END IF;

  INSERT INTO ops.stores (
    name,
    brand_id,
    status,
    address,
    created_at,
    pos_store_id
  )
  VALUES (
    v_name,
    v_office_brand_id,
    'pending'::core.account_status,
    COALESCE(v_address, ''),
    now(),
    p_pos_store_id
  )
  RETURNING id INTO v_office_store_id;

  RETURN v_office_store_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, ops, core, auth;

DROP FUNCTION IF EXISTS public.admin_create_restaurant(text, text, text, text, numeric, uuid, text);
DROP FUNCTION IF EXISTS public.admin_create_restaurant(text, text, text, text, numeric, uuid, text, uuid);

CREATE OR REPLACE FUNCTION public.admin_create_restaurant(
  p_name text,
  p_slug text,
  p_operation_mode text,
  p_address text DEFAULT NULL,
  p_per_person_charge numeric DEFAULT NULL,
  p_brand_id uuid DEFAULT NULL,
  p_store_type text DEFAULT 'direct',
  p_office_store_id uuid DEFAULT NULL
) RETURNS public.restaurants AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_created public.restaurants%ROWTYPE;
  v_new_store_id uuid := gen_random_uuid();
  v_office_store_id uuid;
  v_store_type text := lower(NULLIF(btrim(COALESCE(p_store_type, '')), ''));
  v_operation_mode text := lower(NULLIF(btrim(COALESCE(p_operation_mode, '')), ''));
  v_tax_entity_id uuid;
BEGIN
  IF NULLIF(btrim(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_NAME_REQUIRED';
  END IF;

  IF v_operation_mode IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_OPERATION_MODE_REQUIRED';
  END IF;

  IF p_brand_id IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_BRAND_REQUIRED';
  END IF;

  v_store_type := COALESCE(v_store_type, 'direct');
  IF v_store_type NOT IN ('direct', 'external') THEN
    RAISE EXCEPTION 'RESTAURANT_STORE_TYPE_INVALID';
  END IF;

  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role <> 'super_admin' THEN
    RAISE EXCEPTION 'RESTAURANT_CREATE_FORBIDDEN';
  END IF;

  INSERT INTO public.tax_entity (id, tax_code, name, owner_type, data_source)
  VALUES (
    '00000000-0000-0000-0000-000000000011',
    'PLACEHOLDER_DEV_000',
    'GLOBOSVN Dev Placeholder (replace via onboarding)',
    'internal',
    'VNPT_EPAY'
  )
  ON CONFLICT (id) DO NOTHING;

  SELECT COALESCE(suggested_tax_entity_id, '00000000-0000-0000-0000-000000000011'::uuid)
  INTO v_tax_entity_id
  FROM public.brands
  WHERE id = p_brand_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTAURANT_BRAND_NOT_FOUND';
  END IF;

  IF v_store_type = 'direct' THEN
    v_office_store_id := public.link_office_pending_store_for_pos_store(
      p_pos_store_id => v_new_store_id,
      p_name => p_name,
      p_brand_id => p_brand_id,
      p_address => p_address,
      p_office_store_id => p_office_store_id
    );
  END IF;

  INSERT INTO public.restaurants (
    id,
    name,
    address,
    slug,
    operation_mode,
    per_person_charge,
    brand_id,
    store_type,
    tax_entity_id,
    is_active,
    created_at
  )
  VALUES (
    v_new_store_id,
    btrim(p_name),
    NULLIF(btrim(COALESCE(p_address, '')), ''),
    NULLIF(btrim(COALESCE(p_slug, '')), ''),
    v_operation_mode,
    p_per_person_charge,
    p_brand_id,
    v_store_type,
    v_tax_entity_id,
    TRUE,
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_create_restaurant',
    'restaurants',
    v_created.id,
    jsonb_build_object(
      'restaurant_id', v_created.id,
      'store_id', v_created.id,
      'office_store_id', v_office_store_id,
      'office_store_status', CASE WHEN v_office_store_id IS NULL THEN NULL ELSE 'pending' END,
      'created_at_utc', now(),
      'new_values', jsonb_build_object(
        'name', v_created.name,
        'address', v_created.address,
        'slug', v_created.slug,
        'operation_mode', v_created.operation_mode,
        'per_person_charge', v_created.per_person_charge,
        'brand_id', v_created.brand_id,
        'store_type', v_created.store_type,
        'tax_entity_id', v_created.tax_entity_id,
        'office_store_id', v_office_store_id,
        'is_active', v_created.is_active
      )
    )
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

COMMIT;
