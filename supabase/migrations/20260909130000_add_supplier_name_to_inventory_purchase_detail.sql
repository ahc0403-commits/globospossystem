BEGIN;

-- production-gate: self-verifying

-- Keep the detail contract aligned with the purchase-order list contract so
-- Office can bind the confirmed receipt to a named supplier.
CREATE OR REPLACE FUNCTION public.office_get_inventory_purchase_order_detail(
  p_purchase_order_id uuid
) RETURNS jsonb AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_supplier_name text;
  v_lines jsonb;
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_access_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_OFFICE_FORBIDDEN';
  END IF;

  SELECT supplier.supplier_name
  INTO v_supplier_name
  FROM public.inventory_suppliers supplier
  WHERE supplier.id = v_order.supplier_id;

  SELECT COALESCE(
    jsonb_agg(to_jsonb(line_row) ORDER BY line_row.created_at),
    '[]'::jsonb
  )
  INTO v_lines
  FROM (
    SELECT
      purchase_line.id,
      purchase_line.product_id,
      product.name AS product_name,
      purchase_line.supplier_item_id,
      purchase_line.recommended_quantity_base,
      purchase_line.ordered_quantity_base,
      purchase_line.ordered_quantity_unit,
      purchase_line.order_unit,
      purchase_line.unit_price,
      purchase_line.supply_amount,
      purchase_line.tax_amount,
      purchase_line.memo,
      purchase_line.recommendation_snapshot,
      purchase_line.created_at,
      purchase_line.updated_at
    FROM public.inventory_purchase_order_lines purchase_line
    JOIN public.inventory_products product
      ON product.id = purchase_line.product_id
    WHERE purchase_line.purchase_order_id = p_purchase_order_id
  ) line_row;

  RETURN jsonb_build_object(
    'order',
    to_jsonb(v_order) || jsonb_build_object(
      'supplier_name',
      v_supplier_name
    ),
    'lines',
    v_lines
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth;

DO $verify$
DECLARE
  v_detail_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.office_get_inventory_purchase_order_detail(uuid)'::regprocedure
  ) INTO v_detail_definition;

  IF v_detail_definition NOT LIKE '%''supplier_name'',%'
     OR v_detail_definition NOT LIKE '%v_supplier_name%' THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_DETAIL_SUPPLIER_NAME_MISSING';
  END IF;
END;
$verify$;

COMMIT;
