-- ============================================================
-- Inventory Product Management RPCs
-- 2026-05-06
--
-- POS-native product management for the inventory purchase domain.
-- Keeps inventory_products linked to inventory_items for stock math.
-- ============================================================

CREATE OR REPLACE FUNCTION public.upsert_inventory_product(
  p_store_id UUID,
  p_product_id UUID DEFAULT NULL,
  p_product_code TEXT DEFAULT NULL,
  p_name TEXT DEFAULT NULL,
  p_category TEXT DEFAULT NULL,
  p_stock_unit TEXT DEFAULT NULL,
  p_base_unit TEXT DEFAULT 'g',
  p_base_unit_factor NUMERIC DEFAULT 1000,
  p_image_url TEXT DEFAULT NULL,
  p_storage_type TEXT DEFAULT NULL,
  p_shelf_life_days INT DEFAULT NULL,
  p_is_orderable BOOLEAN DEFAULT TRUE
) RETURNS public.inventory_products AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_product public.inventory_products%ROWTYPE;
  v_inventory_item_id UUID;
  v_name TEXT := NULLIF(BTRIM(COALESCE(p_name, '')), '');
  v_stock_unit TEXT := NULLIF(BTRIM(COALESCE(p_stock_unit, '')), '');
  v_base_unit TEXT := LOWER(NULLIF(BTRIM(COALESCE(p_base_unit, '')), ''));
BEGIN
  -- CHECK: base unit and factor are validated here before product mutation.
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PRODUCT_FORBIDDEN';
  END IF;

  SELECT * INTO v_store
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'PRODUCT_NAME_REQUIRED';
  END IF;

  IF v_stock_unit IS NULL THEN
    RAISE EXCEPTION 'STOCK_UNIT_REQUIRED';
  END IF;

  IF v_base_unit NOT IN ('g', 'ml', 'ea') THEN
    RAISE EXCEPTION 'BASE_UNIT_INVALID';
  END IF;

  IF COALESCE(p_base_unit_factor, 0) <= 0 THEN
    RAISE EXCEPTION 'BASE_UNIT_FACTOR_INVALID';
  END IF;

  IF p_shelf_life_days IS NOT NULL AND p_shelf_life_days < 0 THEN
    RAISE EXCEPTION 'SHELF_LIFE_INVALID';
  END IF;

  IF p_product_id IS NOT NULL THEN
    SELECT *
    INTO v_product
    FROM public.inventory_products
    WHERE id = p_product_id
      AND restaurant_id = p_store_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
    END IF;

    v_inventory_item_id := v_product.inventory_item_id;
  END IF;

  IF v_inventory_item_id IS NULL THEN
    INSERT INTO public.inventory_items (
      restaurant_id,
      name,
      quantity,
      unit,
      current_stock,
      reorder_point,
      cost_per_unit,
      supplier_name,
      is_active
    ) VALUES (
      p_store_id,
      v_name,
      0,
      v_base_unit,
      0,
      0,
      0,
      NULL,
      TRUE
    )
    RETURNING id INTO v_inventory_item_id;
  ELSE
    UPDATE public.inventory_items
    SET name = v_name,
        unit = v_base_unit,
        is_active = TRUE
    WHERE id = v_inventory_item_id
      AND restaurant_id = p_store_id;
  END IF;

  IF p_product_id IS NULL THEN
    INSERT INTO public.inventory_products (
      restaurant_id,
      brand_id,
      inventory_item_id,
      product_code,
      name,
      category,
      stock_unit,
      base_unit,
      base_unit_factor,
      image_url,
      storage_type,
      shelf_life_days,
      is_orderable,
      is_active
    ) VALUES (
      p_store_id,
      v_store.brand_id,
      v_inventory_item_id,
      NULLIF(BTRIM(COALESCE(p_product_code, '')), ''),
      v_name,
      NULLIF(BTRIM(COALESCE(p_category, '')), ''),
      v_stock_unit,
      v_base_unit,
      p_base_unit_factor,
      NULLIF(BTRIM(COALESCE(p_image_url, '')), ''),
      NULLIF(BTRIM(COALESCE(p_storage_type, '')), ''),
      p_shelf_life_days,
      COALESCE(p_is_orderable, TRUE),
      TRUE
    )
    RETURNING * INTO v_product;
  ELSE
    UPDATE public.inventory_products
    SET inventory_item_id = v_inventory_item_id,
        product_code = NULLIF(BTRIM(COALESCE(p_product_code, '')), ''),
        name = v_name,
        category = NULLIF(BTRIM(COALESCE(p_category, '')), ''),
        stock_unit = v_stock_unit,
        base_unit = v_base_unit,
        base_unit_factor = p_base_unit_factor,
        image_url = NULLIF(BTRIM(COALESCE(p_image_url, '')), ''),
        storage_type = NULLIF(BTRIM(COALESCE(p_storage_type, '')), ''),
        shelf_life_days = p_shelf_life_days,
        is_orderable = COALESCE(p_is_orderable, TRUE),
        is_active = TRUE,
        updated_at = now()
    WHERE id = p_product_id
      AND restaurant_id = p_store_id
    RETURNING * INTO v_product;
  END IF;

  RETURN v_product;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.set_inventory_product_active(
  p_store_id UUID,
  p_product_id UUID,
  p_is_active BOOLEAN
) RETURNS public.inventory_products AS $$
DECLARE
  v_product public.inventory_products%ROWTYPE;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PRODUCT_FORBIDDEN';
  END IF;

  UPDATE public.inventory_products
  SET is_active = COALESCE(p_is_active, FALSE),
      is_orderable = CASE WHEN COALESCE(p_is_active, FALSE) THEN is_orderable ELSE FALSE END,
      updated_at = now()
  WHERE id = p_product_id
    AND restaurant_id = p_store_id
  RETURNING * INTO v_product;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
  END IF;

  IF v_product.inventory_item_id IS NOT NULL THEN
    UPDATE public.inventory_items
    SET is_active = COALESCE(p_is_active, FALSE)
    WHERE id = v_product.inventory_item_id
      AND restaurant_id = p_store_id;
  END IF;

  RETURN v_product;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.upsert_inventory_product(
  UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT, INT, BOOLEAN
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_inventory_product_active(UUID, UUID, BOOLEAN) TO authenticated;
