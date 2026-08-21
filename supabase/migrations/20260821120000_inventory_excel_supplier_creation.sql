-- Let ingredient Excel imports create a missing supplier by name while
-- preserving atomic validation of the supplier, product, and purchase price.

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
  v_product public.inventory_products%ROWTYPE;
  v_product_id uuid;
  v_code_owner_id uuid;
  v_supplier public.inventory_suppliers%ROWTYPE;
  v_supplier_id uuid;
  v_store_brand_id uuid;
  v_product_code text;
  v_name text;
  v_category text;
  v_stock_unit text;
  v_base_unit text;
  v_base_unit_factor numeric(12,3);
  v_storage_type text;
  v_shelf_life_days integer;
  v_is_orderable boolean;
  v_supplier_name text;
  v_existing_supplier_name text;
  v_unit_price numeric(12,2);
  v_count integer;
  v_supplier_match_count integer;
  v_created integer := 0;
  v_updated integer := 0;
  v_supplier_created integer := 0;
  v_seen_codes text[] := ARRAY[]::text[];
  v_normalized_code text;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_INGREDIENT_IMPORT_FORBIDDEN';
  END IF;

  SELECT store.brand_id
  INTO v_store_brand_id
  FROM public.restaurants store
  WHERE store.id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
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
      v_supplier_id := NULLIF(v_row->>'supplier_id', '')::uuid;
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
      v_supplier_name :=
        NULLIF(BTRIM(COALESCE(v_row->>'supplier_name', '')), '');
      v_unit_price := NULLIF(v_row->>'unit_price', '')::numeric(12,2);
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
    IF v_supplier_id IS NOT NULL THEN
      SELECT supplier.supplier_name
      INTO v_existing_supplier_name
      FROM public.inventory_suppliers supplier
      WHERE supplier.id = v_supplier_id
        AND supplier.status = 'active'
        AND (
          supplier.brand_id IS NULL
          OR supplier.brand_id = v_store_brand_id
        );

      IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_INGREDIENT_SUPPLIER_NOT_FOUND:%',
          COALESCE(v_source_row::text, '?');
      END IF;

      -- Cached clients from the supplier-price release sent only the id.
      -- Resolve its name server-side during the DB-first deployment window.
      IF v_supplier_name IS NULL THEN
        v_supplier_name := v_existing_supplier_name;
      ELSIF lower(v_supplier_name) <>
            lower(BTRIM(v_existing_supplier_name)) THEN
        RAISE EXCEPTION 'INVENTORY_INGREDIENT_SUPPLIER_NOT_FOUND:%',
          COALESCE(v_source_row::text, '?');
      END IF;
    ELSE
      IF v_supplier_name IS NULL THEN
        RAISE EXCEPTION 'INVENTORY_INGREDIENT_SUPPLIER_REQUIRED:%',
          COALESCE(v_source_row::text, '?');
      END IF;

      SELECT count(*)
      INTO v_supplier_match_count
      FROM public.inventory_suppliers supplier
      WHERE supplier.status = 'active'
        AND (
          supplier.brand_id IS NULL
          OR supplier.brand_id = v_store_brand_id
        )
        AND lower(BTRIM(supplier.supplier_name)) = lower(v_supplier_name);

      IF v_supplier_match_count > 1 THEN
        RAISE EXCEPTION 'INVENTORY_INGREDIENT_SUPPLIER_AMBIGUOUS:%',
          COALESCE(v_source_row::text, '?');
      END IF;
    END IF;

    IF v_unit_price IS NULL OR v_unit_price < 0 THEN
      RAISE EXCEPTION 'INVENTORY_INGREDIENT_PRICE_INVALID:%',
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
    v_supplier_id := NULLIF(v_row->>'supplier_id', '')::uuid;
    v_product_code := BTRIM(v_row->>'product_code');
    v_supplier_name := BTRIM(v_row->>'supplier_name');
    v_unit_price := (v_row->>'unit_price')::numeric(12,2);

    IF v_supplier_id IS NULL THEN
      -- Serialize Excel-created suppliers with the same brand/name so two
      -- concurrent imports do not create duplicate master-data rows.
      PERFORM pg_advisory_xact_lock(
        hashtextextended(
          COALESCE(v_store_brand_id::text, 'global')
            || ':' || lower(v_supplier_name),
          0
        )
      );

      SELECT count(*),
             (array_agg(
               supplier.id
               ORDER BY
                 CASE WHEN supplier.brand_id = v_store_brand_id THEN 0 ELSE 1 END,
                 supplier.created_at,
                 supplier.id
             ))[1]
      INTO v_supplier_match_count, v_supplier_id
      FROM public.inventory_suppliers supplier
      WHERE supplier.status = 'active'
        AND (
          supplier.brand_id IS NULL
          OR supplier.brand_id = v_store_brand_id
        )
        AND lower(BTRIM(supplier.supplier_name)) = lower(v_supplier_name);

      IF v_supplier_match_count > 1 THEN
        RAISE EXCEPTION 'INVENTORY_INGREDIENT_SUPPLIER_AMBIGUOUS:%',
          COALESCE(v_row->>'source_row', '?');
      END IF;

      IF v_supplier_id IS NULL THEN
        SELECT *
        INTO v_supplier
        FROM public.upsert_inventory_supplier(
          p_store_id => p_store_id,
          p_supplier_name => v_supplier_name
        );
        v_supplier_id := v_supplier.id;
        v_supplier_created := v_supplier_created + 1;
      END IF;
    END IF;

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

    v_product := public.upsert_inventory_product(
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

    PERFORM public.upsert_inventory_supplier_item(
      p_store_id := p_store_id,
      p_supplier_item_id := NULL,
      p_supplier_id := v_supplier_id,
      p_product_id := v_product.id,
      p_supplier_sku := NULL,
      p_order_unit := v_product.stock_unit,
      p_order_unit_quantity_base := v_product.base_unit_factor,
      p_min_order_quantity := 1,
      p_unit_price := v_unit_price,
      p_tax_rate := 0,
      p_lead_time_days := 1,
      p_is_preferred := TRUE
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
      'updated_count', v_updated,
      'supplier_price_count', v_count,
      'supplier_created_count', v_supplier_created
    )
  );

  RETURN jsonb_build_object(
    'store_id', p_store_id,
    'row_count', v_count,
    'created_count', v_created,
    'updated_count', v_updated,
    'supplier_price_count', v_count,
    'supplier_created_count', v_supplier_created
  );
END;
$$;

REVOKE ALL ON FUNCTION public.bulk_upsert_inventory_ingredients(uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bulk_upsert_inventory_ingredients(uuid, jsonb)
  TO authenticated, service_role;
