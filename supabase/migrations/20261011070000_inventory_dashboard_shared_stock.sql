BEGIN;
CREATE OR REPLACE FUNCTION public.get_inventory_purchase_dashboard_v2(
  p_store_id UUID DEFAULT NULL,
  p_brand_id UUID DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_scope_store_ids UUID[];
  v_total_inventory_amount NUMERIC(12,2);
  v_submitted_purchase_amount NUMERIC(12,2);
  v_approved_purchase_amount NUMERIC(12,2);
BEGIN
  SELECT ARRAY_AGG(r.id)
  INTO v_scope_store_ids
  FROM public.restaurants r
  WHERE (p_store_id IS NULL OR r.id = p_store_id)
    AND (p_brand_id IS NULL OR r.brand_id = p_brand_id)
    AND public.can_access_inventory_purchase_store(r.id);

  IF v_scope_store_ids IS NULL OR array_length(v_scope_store_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  SELECT COALESCE(SUM(COALESCE(ii.current_stock, 0) * COALESCE(ii.cost_per_unit, 0)), 0)
  INTO v_total_inventory_amount
  FROM public.inventory_products ip
  LEFT JOIN public.inventory_items ii
    ON ii.id = ip.inventory_item_id
   AND ii.restaurant_id = ip.restaurant_id
  WHERE ip.restaurant_id = ANY(v_scope_store_ids)
    AND ip.is_active = TRUE;

  SELECT COALESCE(SUM(total_amount) FILTER (WHERE status = 'submitted'), 0),
         COALESCE(SUM(total_amount) FILTER (WHERE status = 'office_approved'), 0)
  INTO v_submitted_purchase_amount, v_approved_purchase_amount
  FROM public.inventory_purchase_orders
  WHERE restaurant_id = ANY(v_scope_store_ids) AND status IN ('submitted','office_approved');

  -- Low stock is composed from the shared stock-status read by InventoryService.

  RETURN jsonb_build_object(
    'store_count', array_length(v_scope_store_ids, 1),
    'total_inventory_amount', v_total_inventory_amount,
    'submitted_purchase_amount', v_submitted_purchase_amount,
    'approved_purchase_amount', v_approved_purchase_amount
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth;
REVOKE ALL ON FUNCTION public.get_inventory_purchase_dashboard_v2(uuid,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_inventory_purchase_dashboard_v2(uuid,uuid) TO authenticated;
COMMIT;
