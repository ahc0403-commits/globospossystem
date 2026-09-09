BEGIN;

-- production-gate: self-verifying
-- Make the non-fiscal BunsikClub SAMPLE purchase pilot behave like the live
-- Binh Thanh store without sharing stock balances or weakening role/RLS
-- boundaries. Product, supplier-price, and order-unit master data is mirrored;
-- the existing four distinct operational actors keep maker-checker separation.

DO $sample_purchase_pilot$
DECLARE
  v_source_store_id constant uuid :=
    '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid;
  v_sample_store_id constant uuid :=
    '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid;
  v_brand_id constant uuid :=
    'a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878'::uuid;
  v_sample_tax_entity_id constant uuid :=
    '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid;
  v_accounting_user_id uuid;
  v_source_product_count integer;
  v_source_supplier_item_count integer;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurants store
    WHERE store.id = v_source_store_id
      AND store.name = 'BunsikClub Binh Thanh'
      AND store.brand_id = v_brand_id
      AND store.is_active
  ) THEN
    RAISE EXCEPTION 'SAMPLE_PURCHASE_PILOT_SOURCE_STORE_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurants store
    JOIN public.tax_entity entity ON entity.id = store.tax_entity_id
    WHERE store.id = v_sample_store_id
      AND store.name = 'BunsikClub SAMPLE'
      AND store.brand_id = v_brand_id
      AND store.tax_entity_id = v_sample_tax_entity_id
      AND store.is_active
      AND entity.tax_code = 'PENDING_SAMPLE_STORE_TAX_PROFILE'
  ) THEN
    RAISE EXCEPTION 'SAMPLE_PURCHASE_PILOT_TARGET_STORE_INVALID';
  END IF;

  SELECT count(*)
  INTO v_source_product_count
  FROM public.inventory_products product
  WHERE product.restaurant_id = v_source_store_id;

  SELECT count(*)
  INTO v_source_supplier_item_count
  FROM public.inventory_supplier_items supplier_item
  JOIN public.inventory_products product
    ON product.id = supplier_item.product_id
  WHERE product.restaurant_id = v_source_store_id;

  IF v_source_product_count = 0 OR v_source_supplier_item_count = 0 THEN
    RAISE EXCEPTION
      'SAMPLE_PURCHASE_PILOT_SOURCE_MASTER_DATA_EMPTY products=% supplier_items=%',
      v_source_product_count,
      v_source_supplier_item_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.users actor
    WHERE actor.fixed_account_code = 'sp_order'
      AND actor.role = 'inventory_orderer'
      AND actor.account_type = 'inventory_orderer'
      AND actor.restaurant_id = v_sample_store_id
      AND actor.is_active
      AND EXISTS (
        SELECT 1
        FROM public.user_accessible_stores(actor.auth_id) scope(store_id)
        WHERE scope.store_id = v_sample_store_id
      )
  ) THEN
    RAISE EXCEPTION 'SAMPLE_PURCHASE_PILOT_ORDERER_NOT_READY';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.users actor
    WHERE actor.fixed_account_code = 'bunsik_sm2'
      AND actor.role = 'store_admin'
      AND actor.account_type = 'store_manager'
      AND actor.restaurant_id = v_sample_store_id
      AND actor.is_active
      AND EXISTS (
        SELECT 1
        FROM public.user_accessible_stores(actor.auth_id) scope(store_id)
        WHERE scope.store_id = v_sample_store_id
      )
  ) THEN
    RAISE EXCEPTION 'SAMPLE_PURCHASE_PILOT_STORE_APPROVER_NOT_READY';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.users actor
    WHERE actor.fixed_account_code = 'bunsik_bm1'
      AND actor.role = 'brand_admin'
      AND actor.account_type = 'brand_manager'
      AND actor.brand_id = v_brand_id
      AND actor.is_active
      AND EXISTS (
        SELECT 1
        FROM public.user_accessible_stores(actor.auth_id) scope(store_id)
        WHERE scope.store_id = v_sample_store_id
      )
  ) THEN
    RAISE EXCEPTION 'SAMPLE_PURCHASE_PILOT_BRAND_APPROVER_NOT_READY';
  END IF;

  SELECT actor.id
  INTO v_accounting_user_id
  FROM public.users actor
  WHERE actor.fixed_account_code = 'account'
    AND actor.role = 'inventory_accounting'
    AND actor.account_type = 'inventory_accounting'
    AND actor.is_active;

  IF v_accounting_user_id IS NULL THEN
    RAISE EXCEPTION 'SAMPLE_PURCHASE_PILOT_ACCOUNTING_NOT_READY';
  END IF;

  INSERT INTO public.user_tax_entity_access (
    user_id,
    tax_entity_id,
    is_active,
    granted_by,
    created_at,
    updated_at
  ) VALUES (
    v_accounting_user_id,
    v_sample_tax_entity_id,
    true,
    NULL,
    now(),
    now()
  )
  ON CONFLICT (user_id, tax_entity_id) DO UPDATE
  SET is_active = true,
      updated_at = now();

  INSERT INTO public.inventory_items (
    id,
    restaurant_id,
    name,
    quantity,
    unit,
    current_stock,
    reorder_point,
    cost_per_unit,
    supplier_name,
    is_active,
    created_at,
    updated_at
  )
  SELECT
    md5('sample-pilot-inventory-item:' || source_product.id::text)::uuid,
    v_sample_store_id,
    source_item.name,
    0,
    source_item.unit,
    0,
    source_item.reorder_point,
    source_item.cost_per_unit,
    source_item.supplier_name,
    source_item.is_active,
    now(),
    now()
  FROM public.inventory_products source_product
  JOIN public.inventory_items source_item
    ON source_item.id = source_product.inventory_item_id
  WHERE source_product.restaurant_id = v_source_store_id
  ON CONFLICT (id) DO UPDATE
  SET name = EXCLUDED.name,
      unit = EXCLUDED.unit,
      reorder_point = EXCLUDED.reorder_point,
      cost_per_unit = EXCLUDED.cost_per_unit,
      supplier_name = EXCLUDED.supplier_name,
      is_active = EXCLUDED.is_active,
      updated_at = now();

  INSERT INTO public.inventory_products (
    id,
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
    is_active,
    created_at,
    updated_at
  )
  SELECT
    md5('sample-pilot-product:' || source_product.id::text)::uuid,
    v_sample_store_id,
    v_brand_id,
    md5('sample-pilot-inventory-item:' || source_product.id::text)::uuid,
    source_product.product_code,
    source_product.name,
    source_product.category,
    source_product.stock_unit,
    source_product.base_unit,
    source_product.base_unit_factor,
    source_product.image_url,
    source_product.storage_type,
    source_product.shelf_life_days,
    source_product.is_orderable,
    source_product.is_active,
    now(),
    now()
  FROM public.inventory_products source_product
  WHERE source_product.restaurant_id = v_source_store_id
  ON CONFLICT (restaurant_id, product_code) DO UPDATE
  SET brand_id = EXCLUDED.brand_id,
      inventory_item_id = EXCLUDED.inventory_item_id,
      name = EXCLUDED.name,
      category = EXCLUDED.category,
      stock_unit = EXCLUDED.stock_unit,
      base_unit = EXCLUDED.base_unit,
      base_unit_factor = EXCLUDED.base_unit_factor,
      image_url = EXCLUDED.image_url,
      storage_type = EXCLUDED.storage_type,
      shelf_life_days = EXCLUDED.shelf_life_days,
      is_orderable = EXCLUDED.is_orderable,
      is_active = EXCLUDED.is_active,
      updated_at = now();

  INSERT INTO public.inventory_supplier_items (
    id,
    supplier_id,
    product_id,
    supplier_sku,
    order_unit,
    order_unit_quantity_base,
    min_order_quantity,
    unit_price,
    tax_rate,
    lead_time_days,
    is_preferred,
    is_active,
    created_at,
    updated_at
  )
  SELECT
    md5('sample-pilot-supplier-item:' || source_supplier_item.id::text)::uuid,
    source_supplier_item.supplier_id,
    sample_product.id,
    source_supplier_item.supplier_sku,
    source_supplier_item.order_unit,
    source_supplier_item.order_unit_quantity_base,
    source_supplier_item.min_order_quantity,
    source_supplier_item.unit_price,
    source_supplier_item.tax_rate,
    source_supplier_item.lead_time_days,
    source_supplier_item.is_preferred,
    source_supplier_item.is_active,
    now(),
    now()
  FROM public.inventory_supplier_items source_supplier_item
  JOIN public.inventory_products source_product
    ON source_product.id = source_supplier_item.product_id
   AND source_product.restaurant_id = v_source_store_id
  JOIN public.inventory_products sample_product
    ON sample_product.restaurant_id = v_sample_store_id
   AND sample_product.product_code = source_product.product_code
  ON CONFLICT (supplier_id, product_id, order_unit) DO UPDATE
  SET supplier_sku = EXCLUDED.supplier_sku,
      order_unit_quantity_base = EXCLUDED.order_unit_quantity_base,
      min_order_quantity = EXCLUDED.min_order_quantity,
      unit_price = EXCLUDED.unit_price,
      tax_rate = EXCLUDED.tax_rate,
      lead_time_days = EXCLUDED.lead_time_days,
      is_preferred = EXCLUDED.is_preferred,
      is_active = EXCLUDED.is_active,
      updated_at = now();

  IF NOT EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(
      (SELECT auth_id FROM public.users WHERE id = v_accounting_user_id)
    ) scope(store_id)
    WHERE scope.store_id = v_sample_store_id
  ) THEN
    RAISE EXCEPTION 'SAMPLE_PURCHASE_PILOT_ACCOUNTING_SCOPE_FAILED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_products source_product
    WHERE source_product.restaurant_id = v_source_store_id
      AND NOT EXISTS (
        SELECT 1
        FROM public.inventory_products sample_product
        WHERE sample_product.restaurant_id = v_sample_store_id
          AND sample_product.product_code = source_product.product_code
          AND sample_product.name = source_product.name
          AND sample_product.brand_id = v_brand_id
          AND sample_product.is_orderable = source_product.is_orderable
          AND sample_product.is_active = source_product.is_active
      )
  ) THEN
    RAISE EXCEPTION 'SAMPLE_PURCHASE_PILOT_PRODUCT_PARITY_FAILED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_supplier_items source_supplier_item
    JOIN public.inventory_products source_product
      ON source_product.id = source_supplier_item.product_id
     AND source_product.restaurant_id = v_source_store_id
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.inventory_products sample_product
      JOIN public.inventory_supplier_items sample_supplier_item
        ON sample_supplier_item.product_id = sample_product.id
      WHERE sample_product.restaurant_id = v_sample_store_id
        AND sample_product.product_code = source_product.product_code
        AND sample_supplier_item.supplier_id =
          source_supplier_item.supplier_id
        AND sample_supplier_item.order_unit = source_supplier_item.order_unit
        AND sample_supplier_item.is_active = source_supplier_item.is_active
        AND sample_supplier_item.unit_price = source_supplier_item.unit_price
    )
  ) THEN
    RAISE EXCEPTION 'SAMPLE_PURCHASE_PILOT_SUPPLIER_ITEM_PARITY_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.v_office_eligible_stores eligible
    WHERE eligible.store_id = v_sample_store_id
      AND eligible.brand_id = v_brand_id
      AND eligible.tax_entity_id = v_sample_tax_entity_id
      AND eligible.is_active
  ) THEN
    RAISE EXCEPTION 'SAMPLE_PURCHASE_PILOT_OFFICE_BRIDGE_NOT_READY';
  END IF;
END;
$sample_purchase_pilot$;

COMMIT;
