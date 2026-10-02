-- Save safety stock with the existing product/supplier transaction. Old clients
-- keep their RPC and existing thresholds; this endpoint explicitly supports NULL.
CREATE OR REPLACE FUNCTION public.upsert_inventory_product_with_supplier_v2(
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
  p_supplier_sku TEXT DEFAULT NULL,
  p_safety_stock_base NUMERIC DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_result JSONB;
  v_product public.inventory_products%ROWTYPE;
  v_supplier_item public.inventory_supplier_items%ROWTYPE;
  v_previous_supplier_item public.inventory_supplier_items%ROWTYPE;
  v_item public.inventory_items%ROWTYPE;
  v_threshold NUMERIC(12,3);
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTHENTICATION_REQUIRED';
  END IF;
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PRODUCT_FORBIDDEN';
  END IF;
  IF p_safety_stock_base IS NOT NULL AND (
    p_safety_stock_base::text IN ('NaN','Infinity','-Infinity')
    OR p_safety_stock_base < 0 OR p_safety_stock_base > 999999999.999
  ) THEN
    RAISE EXCEPTION 'INVENTORY_SAFETY_STOCK_INVALID';
  END IF;
  v_threshold := p_safety_stock_base;
  v_product := public.upsert_inventory_product(
    p_store_id, p_product_id, p_product_code, p_name, p_category, p_stock_unit,
    p_base_unit, p_base_unit_factor, p_image_url, p_storage_type,
    p_shelf_life_days, p_is_orderable
  );
  -- Retain commercial terms when editing the product or its safety stock.
  -- The original combined RPC supplies defaults (price 0, lead time 1).
  SELECT * INTO v_previous_supplier_item FROM public.inventory_supplier_items
  WHERE product_id=v_product.id AND supplier_id=p_supplier_id AND is_active=true
  ORDER BY (order_unit=BTRIM(p_stock_unit)) DESC, is_preferred DESC,
    updated_at DESC, id DESC LIMIT 1 FOR UPDATE;
  v_supplier_item := public.upsert_inventory_supplier_item(
    p_store_id := p_store_id, p_supplier_id := p_supplier_id,
    p_product_id := v_product.id, p_supplier_sku := p_supplier_sku,
    p_order_unit := v_product.stock_unit,
    p_order_unit_quantity_base := v_product.base_unit_factor,
    p_min_order_quantity := COALESCE(v_previous_supplier_item.min_order_quantity,1),
    p_unit_price := COALESCE(v_previous_supplier_item.unit_price,0),
    p_tax_rate := COALESCE(v_previous_supplier_item.tax_rate,0),
    p_lead_time_days := COALESCE(v_previous_supplier_item.lead_time_days,1),
    p_is_preferred := TRUE
  );
  v_result := jsonb_build_object('product',to_jsonb(v_product),
    'supplier_item',to_jsonb(v_supplier_item));
  SELECT * INTO v_item FROM public.inventory_items
  WHERE id = (v_result->'product'->>'inventory_item_id')::uuid
    AND restaurant_id = p_store_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PRODUCT_NOT_FOUND'; END IF;
  IF v_item.reorder_point IS DISTINCT FROM v_threshold THEN
    -- Never write quantity/current_stock: changing a warning threshold does not
    -- establish a count baseline or create an inventory movement.
    UPDATE public.inventory_items SET reorder_point = v_threshold, updated_at = now()
    WHERE id = v_item.id AND restaurant_id = p_store_id;
    INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
    VALUES(auth.uid(), 'inventory_safety_stock_updated', 'inventory_items', v_item.id,
      jsonb_build_object('store_id',p_store_id,'old_reorder_point',v_item.reorder_point,
        'new_reorder_point',v_threshold,'base_unit',v_product.base_unit));
  END IF;
  RETURN v_result || jsonb_build_object('safety_stock_base',v_threshold);
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_inventory_product_with_supplier_v2(
  UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,NUMERIC,TEXT,TEXT,INT,BOOLEAN,TEXT,NUMERIC
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_inventory_product_with_supplier_v2(
  UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,NUMERIC,TEXT,TEXT,INT,BOOLEAN,TEXT,NUMERIC
) TO authenticated;
NOTIFY pgrst, 'reload schema';
