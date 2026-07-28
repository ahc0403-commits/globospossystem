-- Save an ingredient and its preferred supplier as one transaction.
-- The existing inventory_supplier_items table remains the source of truth so
-- ingredients may keep multiple supplier relationships.
CREATE OR REPLACE FUNCTION public.upsert_inventory_product_with_supplier(
  p_store_id UUID,
  p_supplier_id UUID,
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
  p_is_orderable BOOLEAN DEFAULT TRUE,
  p_supplier_sku TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_product public.inventory_products%ROWTYPE;
  v_supplier_item public.inventory_supplier_items%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTHENTICATION_REQUIRED';
  END IF;

  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PRODUCT_FORBIDDEN';
  END IF;

  IF p_supplier_id IS NULL THEN
    RAISE EXCEPTION 'SUPPLIER_REQUIRED';
  END IF;

  v_product := public.upsert_inventory_product(
    p_store_id,
    p_product_id,
    p_product_code,
    p_name,
    p_category,
    p_stock_unit,
    p_base_unit,
    p_base_unit_factor,
    p_image_url,
    p_storage_type,
    p_shelf_life_days,
    p_is_orderable
  );

  v_supplier_item := public.upsert_inventory_supplier_item(
    p_store_id := p_store_id,
    p_supplier_item_id := NULL,
    p_supplier_id := p_supplier_id,
    p_product_id := v_product.id,
    p_supplier_sku := p_supplier_sku,
    p_order_unit := v_product.stock_unit,
    p_order_unit_quantity_base := v_product.base_unit_factor,
    p_min_order_quantity := 1,
    p_unit_price := 0,
    p_tax_rate := 0,
    p_lead_time_days := 1,
    p_is_preferred := TRUE
  );

  RETURN jsonb_build_object(
    'product', to_jsonb(v_product),
    'supplier_item', to_jsonb(v_supplier_item)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_inventory_product_with_supplier(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT, INT,
  BOOLEAN, TEXT
) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.upsert_inventory_product_with_supplier(
  UUID, UUID, UUID, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT, INT,
  BOOLEAN, TEXT
) TO authenticated;
