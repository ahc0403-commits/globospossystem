-- Supplier settlement details, store-scoped recipe access, and atomic
-- ingredient Excel import for the Restaurant inventory workspace.

ALTER TABLE public.inventory_suppliers
  ADD COLUMN IF NOT EXISTS bank_account_number text,
  ADD COLUMN IF NOT EXISTS bank_name text,
  ADD COLUMN IF NOT EXISTS bank_account_holder text;

DROP FUNCTION IF EXISTS public.upsert_inventory_supplier(
  uuid, uuid, text, text, text, text, text, text, text, text, date, date,
  text
);
DROP FUNCTION IF EXISTS public.upsert_inventory_supplier(
  uuid, uuid, text, text, text, text, text, text, text, text, date, date,
  text, text
);

CREATE OR REPLACE FUNCTION public.upsert_inventory_supplier(
  p_store_id uuid,
  p_supplier_id uuid DEFAULT NULL,
  p_supplier_name text DEFAULT NULL,
  p_supplier_type text DEFAULT NULL,
  p_contact_name text DEFAULT NULL,
  p_phone text DEFAULT NULL,
  p_email text DEFAULT NULL,
  p_address text DEFAULT NULL,
  p_business_registration_no text DEFAULT NULL,
  p_payment_terms text DEFAULT NULL,
  p_contract_start_date date DEFAULT NULL,
  p_contract_end_date date DEFAULT NULL,
  p_memo text DEFAULT NULL,
  p_bank_account_number text DEFAULT NULL,
  p_bank_name text DEFAULT NULL,
  p_bank_account_holder text DEFAULT NULL
) RETURNS public.inventory_suppliers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_supplier public.inventory_suppliers%ROWTYPE;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_SUPPLIER_FORBIDDEN';
  END IF;

  SELECT * INTO v_store
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_supplier_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'SUPPLIER_NAME_REQUIRED';
  END IF;

  IF p_supplier_id IS NULL THEN
    INSERT INTO public.inventory_suppliers (
      brand_id,
      supplier_name,
      supplier_type,
      contact_name,
      phone,
      email,
      address,
      business_registration_no,
      bank_account_number,
      bank_name,
      bank_account_holder,
      payment_terms,
      contract_start_date,
      contract_end_date,
      status,
      memo
    ) VALUES (
      v_store.brand_id,
      BTRIM(p_supplier_name),
      NULLIF(BTRIM(COALESCE(p_supplier_type, '')), ''),
      NULLIF(BTRIM(COALESCE(p_contact_name, '')), ''),
      NULLIF(BTRIM(COALESCE(p_phone, '')), ''),
      NULLIF(BTRIM(COALESCE(p_email, '')), ''),
      NULLIF(BTRIM(COALESCE(p_address, '')), ''),
      NULLIF(BTRIM(COALESCE(p_business_registration_no, '')), ''),
      NULLIF(BTRIM(COALESCE(p_bank_account_number, '')), ''),
      NULLIF(BTRIM(COALESCE(p_bank_name, '')), ''),
      NULLIF(BTRIM(COALESCE(p_bank_account_holder, '')), ''),
      NULLIF(BTRIM(COALESCE(p_payment_terms, '')), ''),
      p_contract_start_date,
      p_contract_end_date,
      'active',
      NULLIF(BTRIM(COALESCE(p_memo, '')), '')
    )
    RETURNING * INTO v_supplier;
  ELSE
    UPDATE public.inventory_suppliers
    SET supplier_name = BTRIM(p_supplier_name),
        supplier_type = NULLIF(BTRIM(COALESCE(p_supplier_type, '')), ''),
        contact_name = NULLIF(BTRIM(COALESCE(p_contact_name, '')), ''),
        phone = NULLIF(BTRIM(COALESCE(p_phone, '')), ''),
        email = NULLIF(BTRIM(COALESCE(p_email, '')), ''),
        address = NULLIF(BTRIM(COALESCE(p_address, '')), ''),
        business_registration_no =
          NULLIF(BTRIM(COALESCE(p_business_registration_no, '')), ''),
        bank_account_number =
          NULLIF(BTRIM(COALESCE(p_bank_account_number, '')), ''),
        bank_name = NULLIF(BTRIM(COALESCE(p_bank_name, '')), ''),
        bank_account_holder =
          NULLIF(BTRIM(COALESCE(p_bank_account_holder, '')), ''),
        payment_terms = NULLIF(BTRIM(COALESCE(p_payment_terms, '')), ''),
        contract_start_date = p_contract_start_date,
        contract_end_date = p_contract_end_date,
        memo = NULLIF(BTRIM(COALESCE(p_memo, '')), ''),
        updated_at = now()
    WHERE id = p_supplier_id
      AND (brand_id IS NULL OR brand_id = v_store.brand_id)
    RETURNING * INTO v_supplier;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'SUPPLIER_NOT_FOUND';
    END IF;
  END IF;

  INSERT INTO public.audit_logs(
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  ) VALUES (
    auth.uid(),
    'inventory_supplier_saved',
    'inventory_suppliers',
    v_supplier.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'bank_details_present',
        v_supplier.bank_account_number IS NOT NULL
        OR v_supplier.bank_name IS NOT NULL
        OR v_supplier.bank_account_holder IS NOT NULL
    )
  );

  RETURN v_supplier;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_inventory_supplier(
  uuid, uuid, text, text, text, text, text, text, text, text, date, date,
  text, text, text, text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_inventory_supplier(
  uuid, uuid, text, text, text, text, text, text, text, text, date, date,
  text, text, text, text
) TO authenticated;

COMMENT ON COLUMN public.inventory_suppliers.bank_name IS
  'Bank name for supplier settlement.';
COMMENT ON COLUMN public.inventory_suppliers.bank_account_number IS
  'Supplier bank account number used for settlement and payment reference.';
COMMENT ON COLUMN public.inventory_suppliers.bank_account_holder IS
  'Account holder name for supplier settlement.';

CREATE OR REPLACE FUNCTION public.get_inventory_recipe_catalog(
  p_store_id uuid,
  p_menu_item_id uuid DEFAULT NULL
) RETURNS TABLE (
  recipe_id uuid,
  restaurant_id uuid,
  menu_item_id uuid,
  menu_item_name text,
  ingredient_id uuid,
  ingredient_name text,
  ingredient_unit text,
  quantity_g decimal(10,3),
  last_updated timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_FORBIDDEN';
  END IF;

  IF p_menu_item_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_items item
    WHERE item.id = p_menu_item_id
      AND item.restaurant_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_NOT_FOUND';
  END IF;

  RETURN QUERY
  SELECT
    recipe.id,
    recipe.restaurant_id,
    recipe.menu_item_id,
    menu.name,
    recipe.ingredient_id,
    ingredient.name,
    ingredient.unit,
    recipe.quantity_g,
    recipe.updated_at
  FROM public.menu_recipes recipe
  JOIN public.menu_items menu
    ON menu.id = recipe.menu_item_id
   AND menu.restaurant_id = recipe.restaurant_id
  JOIN public.inventory_items ingredient
    ON ingredient.id = recipe.ingredient_id
   AND ingredient.restaurant_id = recipe.restaurant_id
  WHERE recipe.restaurant_id = p_store_id
    AND (p_menu_item_id IS NULL OR recipe.menu_item_id = p_menu_item_id)
  ORDER BY lower(menu.name), lower(ingredient.name), recipe.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.get_inventory_recipe_catalog(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_inventory_recipe_catalog(uuid, uuid)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.bulk_upsert_inventory_ingredients(
  p_store_id uuid,
  p_rows jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_row jsonb;
  v_source_row integer;
  v_product_id uuid;
  v_code_owner_id uuid;
  v_product_code text;
  v_name text;
  v_category text;
  v_stock_unit text;
  v_base_unit text;
  v_base_unit_factor numeric(12,3);
  v_storage_type text;
  v_shelf_life_days integer;
  v_is_orderable boolean;
  v_count integer;
  v_created integer := 0;
  v_updated integer := 0;
  v_seen_codes text[] := ARRAY[]::text[];
  v_normalized_code text;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_INGREDIENT_IMPORT_FORBIDDEN';
  END IF;

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'INVENTORY_INGREDIENT_IMPORT_ROWS_INVALID';
  END IF;

  v_count := jsonb_array_length(p_rows);
  IF v_count < 1 OR v_count > 1000 THEN
    RAISE EXCEPTION 'INVENTORY_INGREDIENT_IMPORT_SIZE_INVALID';
  END IF;

  -- Validate every row before performing any mutation.
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows)
  LOOP
    BEGIN
      v_source_row := NULLIF(v_row->>'source_row', '')::integer;
      v_product_id := NULLIF(v_row->>'product_id', '')::uuid;
      v_product_code := NULLIF(BTRIM(COALESCE(v_row->>'product_code', '')), '');
      v_name := NULLIF(BTRIM(COALESCE(v_row->>'name', '')), '');
      v_category := NULLIF(BTRIM(COALESCE(v_row->>'category', '')), '');
      v_stock_unit := NULLIF(BTRIM(COALESCE(v_row->>'stock_unit', '')), '');
      v_base_unit := lower(
        NULLIF(BTRIM(COALESCE(v_row->>'base_unit', '')), '')
      );
      v_base_unit_factor :=
        NULLIF(v_row->>'base_unit_factor', '')::numeric(12,3);
      v_storage_type :=
        NULLIF(BTRIM(COALESCE(v_row->>'storage_type', '')), '');
      v_shelf_life_days :=
        NULLIF(v_row->>'shelf_life_days', '')::integer;
      v_is_orderable := COALESCE((v_row->>'is_orderable')::boolean, true);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'INVENTORY_INGREDIENT_IMPORT_ROW_INVALID:%',
        COALESCE(v_row->>'source_row', '?');
    END;

    IF v_product_code IS NULL THEN
      RAISE EXCEPTION 'INVENTORY_INGREDIENT_CODE_REQUIRED:%',
        COALESCE(v_source_row::text, '?');
    END IF;
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'INVENTORY_INGREDIENT_NAME_REQUIRED:%',
        COALESCE(v_source_row::text, '?');
    END IF;
    IF v_stock_unit IS NULL THEN
      RAISE EXCEPTION 'INVENTORY_INGREDIENT_STOCK_UNIT_REQUIRED:%',
        COALESCE(v_source_row::text, '?');
    END IF;
    IF v_base_unit NOT IN ('g', 'ml', 'ea') THEN
      RAISE EXCEPTION 'INVENTORY_INGREDIENT_BASE_UNIT_INVALID:%',
        COALESCE(v_source_row::text, '?');
    END IF;
    IF COALESCE(v_base_unit_factor, 0) <= 0 THEN
      RAISE EXCEPTION 'INVENTORY_INGREDIENT_FACTOR_INVALID:%',
        COALESCE(v_source_row::text, '?');
    END IF;
    IF v_shelf_life_days IS NOT NULL AND v_shelf_life_days < 0 THEN
      RAISE EXCEPTION 'INVENTORY_INGREDIENT_SHELF_LIFE_INVALID:%',
        COALESCE(v_source_row::text, '?');
    END IF;

    v_normalized_code := lower(v_product_code);
    IF v_normalized_code = ANY(v_seen_codes) THEN
      RAISE EXCEPTION 'INVENTORY_INGREDIENT_IMPORT_DUPLICATE:%',
        COALESCE(v_source_row::text, '?');
    END IF;
    v_seen_codes := array_append(v_seen_codes, v_normalized_code);

    SELECT product.id
    INTO v_code_owner_id
    FROM public.inventory_products product
    WHERE product.restaurant_id = p_store_id
      AND lower(product.product_code) = v_normalized_code
    LIMIT 1;

    IF v_product_id IS NOT NULL AND NOT EXISTS (
      SELECT 1
      FROM public.inventory_products product
      WHERE product.id = v_product_id
        AND product.restaurant_id = p_store_id
    ) THEN
      RAISE EXCEPTION 'INVENTORY_INGREDIENT_NOT_FOUND:%',
        COALESCE(v_source_row::text, '?');
    END IF;

    IF v_product_id IS NOT NULL
       AND v_code_owner_id IS NOT NULL
       AND v_code_owner_id <> v_product_id THEN
      RAISE EXCEPTION 'INVENTORY_INGREDIENT_CODE_CONFLICT:%',
        COALESCE(v_source_row::text, '?');
    END IF;
  END LOOP;

  FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows)
  LOOP
    v_product_id := NULLIF(v_row->>'product_id', '')::uuid;
    v_product_code := BTRIM(v_row->>'product_code');
    IF v_product_id IS NULL THEN
      SELECT product.id
      INTO v_product_id
      FROM public.inventory_products product
      WHERE product.restaurant_id = p_store_id
        AND lower(product.product_code) = lower(v_product_code)
      LIMIT 1;
    END IF;

    IF v_product_id IS NULL THEN
      v_created := v_created + 1;
    ELSE
      v_updated := v_updated + 1;
    END IF;

    PERFORM public.upsert_inventory_product(
      p_store_id,
      v_product_id,
      v_product_code,
      BTRIM(v_row->>'name'),
      NULLIF(BTRIM(COALESCE(v_row->>'category', '')), ''),
      BTRIM(v_row->>'stock_unit'),
      lower(BTRIM(v_row->>'base_unit')),
      (v_row->>'base_unit_factor')::numeric,
      NULL,
      NULLIF(BTRIM(COALESCE(v_row->>'storage_type', '')), ''),
      NULLIF(v_row->>'shelf_life_days', '')::integer,
      COALESCE((v_row->>'is_orderable')::boolean, true)
    );
  END LOOP;

  INSERT INTO public.audit_logs(
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  ) VALUES (
    auth.uid(),
    'inventory_ingredient_excel_imported',
    'inventory_products',
    p_store_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'row_count', v_count,
      'created_count', v_created,
      'updated_count', v_updated
    )
  );

  RETURN jsonb_build_object(
    'store_id', p_store_id,
    'row_count', v_count,
    'created_count', v_created,
    'updated_count', v_updated
  );
END;
$$;

REVOKE ALL ON FUNCTION public.bulk_upsert_inventory_ingredients(uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bulk_upsert_inventory_ingredients(uuid, jsonb)
  TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.upsert_inventory_product(
  uuid, uuid, text, text, text, text, text, numeric, text, text, integer,
  boolean
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_inventory_product(
  uuid, uuid, text, text, text, text, text, numeric, text, text, integer,
  boolean
) TO authenticated;
