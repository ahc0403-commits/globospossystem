BEGIN;

-- production-gate: self-verifying

-- A purchase-unit change used to insert a second supplier item because the
-- supplier-item uniqueness key includes order_unit. Reconcile those generated
-- duplicates before making preferred supplier rows update in place.
WITH displaced AS (
  UPDATE public.inventory_supplier_items supplier_item
  SET is_preferred = false,
      is_active = false,
      updated_at = now()
  FROM public.inventory_products product
  WHERE supplier_item.product_id = product.id
    AND supplier_item.is_active = true
    AND supplier_item.is_preferred = true
    AND (
      supplier_item.order_unit IS DISTINCT FROM product.stock_unit
      OR supplier_item.order_unit_quantity_base
        IS DISTINCT FROM product.base_unit_factor
    )
    AND EXISTS (
      SELECT 1
      FROM public.inventory_supplier_items matching
      WHERE matching.supplier_id = supplier_item.supplier_id
        AND matching.product_id = supplier_item.product_id
        AND matching.id <> supplier_item.id
        AND matching.is_active = true
        AND matching.order_unit = product.stock_unit
        AND matching.order_unit_quantity_base = product.base_unit_factor
    )
  RETURNING supplier_item.supplier_id, supplier_item.product_id
)
UPDATE public.inventory_supplier_items matching
SET is_preferred = true,
    updated_at = now()
FROM displaced, public.inventory_products product
WHERE matching.supplier_id = displaced.supplier_id
  AND matching.product_id = displaced.product_id
  AND product.id = matching.product_id
  AND matching.is_active = true
  AND matching.order_unit = product.stock_unit
  AND matching.order_unit_quantity_base = product.base_unit_factor;

WITH ranked_preferred AS (
  SELECT
    supplier_item.id,
    product.stock_unit,
    product.base_unit_factor,
    row_number() OVER (
      PARTITION BY supplier_item.supplier_id, supplier_item.product_id
      ORDER BY supplier_item.updated_at DESC, supplier_item.id DESC
    ) AS preference_rank
  FROM public.inventory_supplier_items supplier_item
  JOIN public.inventory_products product
    ON product.id = supplier_item.product_id
  WHERE supplier_item.is_active = true
    AND supplier_item.is_preferred = true
)
UPDATE public.inventory_supplier_items supplier_item
SET is_preferred = false,
    is_active = false,
    updated_at = now()
FROM ranked_preferred ranked
WHERE ranked.id = supplier_item.id
  AND ranked.preference_rank > 1
  AND (
    supplier_item.order_unit IS DISTINCT FROM ranked.stock_unit
    OR supplier_item.order_unit_quantity_base
      IS DISTINCT FROM ranked.base_unit_factor
  );

UPDATE public.inventory_supplier_items supplier_item
SET order_unit = product.stock_unit,
    order_unit_quantity_base = product.base_unit_factor,
    updated_at = now()
FROM public.inventory_products product
WHERE supplier_item.product_id = product.id
  AND supplier_item.is_active = true
  AND supplier_item.is_preferred = true
  AND (
    supplier_item.order_unit IS DISTINCT FROM product.stock_unit
    OR supplier_item.order_unit_quantity_base
      IS DISTINCT FROM product.base_unit_factor
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.inventory_supplier_items matching
    WHERE matching.supplier_id = supplier_item.supplier_id
      AND matching.product_id = supplier_item.product_id
      AND matching.id <> supplier_item.id
      AND matching.order_unit = product.stock_unit
  );

CREATE OR REPLACE FUNCTION public.upsert_inventory_supplier_item(
  p_store_id UUID,
  p_supplier_item_id UUID DEFAULT NULL,
  p_supplier_id UUID DEFAULT NULL,
  p_product_id UUID DEFAULT NULL,
  p_supplier_sku TEXT DEFAULT NULL,
  p_order_unit TEXT DEFAULT NULL,
  p_order_unit_quantity_base NUMERIC DEFAULT NULL,
  p_min_order_quantity NUMERIC DEFAULT 1,
  p_unit_price NUMERIC DEFAULT 0,
  p_tax_rate NUMERIC DEFAULT 0,
  p_lead_time_days INT DEFAULT 1,
  p_is_preferred BOOLEAN DEFAULT FALSE
) RETURNS public.inventory_supplier_items AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_supplier public.inventory_suppliers%ROWTYPE;
  v_product public.inventory_products%ROWTYPE;
  v_item public.inventory_supplier_items%ROWTYPE;
  v_effective_supplier_item_id UUID := p_supplier_item_id;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_SUPPLIER_ITEM_FORBIDDEN';
  END IF;

  SELECT * INTO v_store
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  SELECT * INTO v_supplier
  FROM public.inventory_suppliers
  WHERE id = p_supplier_id
    AND status = 'active'
    AND (brand_id IS NULL OR brand_id = v_store.brand_id);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'SUPPLIER_NOT_FOUND';
  END IF;

  SELECT * INTO v_product
  FROM public.inventory_products
  WHERE id = p_product_id
    AND restaurant_id = p_store_id
    AND is_active = TRUE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PRODUCT_NOT_FOUND';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_order_unit, '')), '') IS NULL THEN
    RAISE EXCEPTION 'ORDER_UNIT_REQUIRED';
  END IF;
  IF COALESCE(p_order_unit_quantity_base, 0) <= 0 THEN
    RAISE EXCEPTION 'ORDER_UNIT_QUANTITY_INVALID';
  END IF;
  IF COALESCE(p_min_order_quantity, 0) <= 0 THEN
    RAISE EXCEPTION 'MIN_ORDER_QUANTITY_INVALID';
  END IF;
  IF COALESCE(p_unit_price, 0) < 0 THEN
    RAISE EXCEPTION 'UNIT_PRICE_INVALID';
  END IF;
  IF COALESCE(p_tax_rate, 0) < 0 THEN
    RAISE EXCEPTION 'TAX_RATE_INVALID';
  END IF;
  IF COALESCE(p_lead_time_days, 0) < 0 THEN
    RAISE EXCEPTION 'LEAD_TIME_INVALID';
  END IF;

  -- Product and Excel registration call this RPC without an item id. Reuse the
  -- matching/preferred supplier row so changing ea to box updates the order
  -- unit instead of leaving an active stale ea row behind.
  IF v_effective_supplier_item_id IS NULL AND p_is_preferred THEN
    SELECT supplier_item.id
    INTO v_effective_supplier_item_id
    FROM public.inventory_supplier_items supplier_item
    WHERE supplier_item.supplier_id = p_supplier_id
      AND supplier_item.product_id = p_product_id
      AND supplier_item.is_active = true
    ORDER BY
      (supplier_item.order_unit = BTRIM(p_order_unit)) DESC,
      supplier_item.is_preferred DESC,
      supplier_item.updated_at DESC,
      supplier_item.id DESC
    LIMIT 1;
  END IF;

  IF p_is_preferred THEN
    UPDATE public.inventory_supplier_items supplier_item
    SET is_preferred = FALSE,
        is_active = CASE
          WHEN supplier_item.supplier_id = p_supplier_id
            AND supplier_item.is_preferred
            AND supplier_item.order_unit <> BTRIM(p_order_unit)
          THEN FALSE
          ELSE supplier_item.is_active
        END,
        updated_at = now()
    WHERE supplier_item.product_id = p_product_id
      AND supplier_item.id IS DISTINCT FROM v_effective_supplier_item_id;
  END IF;

  IF v_effective_supplier_item_id IS NULL THEN
    INSERT INTO public.inventory_supplier_items (
      supplier_id, product_id, supplier_sku, order_unit,
      order_unit_quantity_base, min_order_quantity, unit_price, tax_rate,
      lead_time_days, is_preferred, is_active
    ) VALUES (
      p_supplier_id, p_product_id,
      NULLIF(BTRIM(COALESCE(p_supplier_sku, '')), ''),
      BTRIM(p_order_unit), p_order_unit_quantity_base, p_min_order_quantity,
      p_unit_price, COALESCE(p_tax_rate, 0), COALESCE(p_lead_time_days, 1),
      COALESCE(p_is_preferred, FALSE), TRUE
    )
    ON CONFLICT (supplier_id, product_id, order_unit)
    DO UPDATE SET supplier_sku = EXCLUDED.supplier_sku,
                  order_unit_quantity_base = EXCLUDED.order_unit_quantity_base,
                  min_order_quantity = EXCLUDED.min_order_quantity,
                  unit_price = EXCLUDED.unit_price,
                  tax_rate = EXCLUDED.tax_rate,
                  lead_time_days = EXCLUDED.lead_time_days,
                  is_preferred = EXCLUDED.is_preferred,
                  is_active = TRUE,
                  updated_at = now()
    RETURNING * INTO v_item;
  ELSE
    UPDATE public.inventory_supplier_items
    SET supplier_sku = NULLIF(BTRIM(COALESCE(p_supplier_sku, '')), ''),
        order_unit = BTRIM(p_order_unit),
        order_unit_quantity_base = p_order_unit_quantity_base,
        min_order_quantity = p_min_order_quantity,
        unit_price = p_unit_price,
        tax_rate = COALESCE(p_tax_rate, 0),
        lead_time_days = COALESCE(p_lead_time_days, 1),
        is_preferred = COALESCE(p_is_preferred, FALSE),
        is_active = TRUE,
        updated_at = now()
    WHERE id = v_effective_supplier_item_id
      AND supplier_id = p_supplier_id
      AND product_id = p_product_id
    RETURNING * INTO v_item;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'SUPPLIER_ITEM_NOT_FOUND';
    END IF;
  END IF;

  RETURN v_item;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

REVOKE ALL ON FUNCTION public.upsert_inventory_supplier_item(
  UUID, UUID, UUID, UUID, TEXT, TEXT, NUMERIC, NUMERIC, NUMERIC, NUMERIC,
  INT, BOOLEAN
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_inventory_supplier_item(
  UUID, UUID, UUID, UUID, TEXT, TEXT, NUMERIC, NUMERIC, NUMERIC, NUMERIC,
  INT, BOOLEAN
) TO authenticated;

DO $$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_catalog.pg_get_functiondef(
    'public.upsert_inventory_supplier_item(uuid,uuid,uuid,uuid,text,text,numeric,numeric,numeric,numeric,integer,boolean)'
      ::regprocedure
  ) INTO v_definition;

  IF v_definition NOT LIKE '%v_effective_supplier_item_id%'
     OR v_definition NOT LIKE '%order_unit_quantity_base = p_order_unit_quantity_base%'
     OR v_definition NOT LIKE '%supplier_item.order_unit = BTRIM(p_order_unit)%'
     OR NOT pg_catalog.has_function_privilege(
       'authenticated',
       'public.upsert_inventory_supplier_item(uuid,uuid,uuid,uuid,text,text,numeric,numeric,numeric,numeric,integer,boolean)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'INVENTORY_ORDER_UNIT_CONVERSION_SYNC_VERIFICATION_FAILED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_supplier_items supplier_item
    JOIN public.inventory_products product
      ON product.id = supplier_item.product_id
    WHERE supplier_item.is_active = true
      AND supplier_item.is_preferred = true
      AND (
        supplier_item.order_unit IS DISTINCT FROM product.stock_unit
        OR supplier_item.order_unit_quantity_base
          IS DISTINCT FROM product.base_unit_factor
      )
  ) THEN
    RAISE EXCEPTION 'INVENTORY_ORDER_UNIT_DATA_SYNC_VERIFICATION_FAILED';
  END IF;
END;
$$;

COMMIT;
