-- ============================================================
-- Inventory Purchase Receipt Confirmation
-- 2026-05-06
--
-- Office approval does not change stock. Stock increases only when receipt is
-- confirmed from an approved/ordered purchase order.
-- ============================================================

CREATE OR REPLACE FUNCTION public.confirm_inventory_purchase_receipt(
  p_purchase_order_id UUID,
  p_memo TEXT DEFAULT NULL,
  p_lines JSONB DEFAULT '[]'::JSONB
) RETURNS public.inventory_purchase_orders AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_receipt_id UUID;
  v_line JSONB;
  v_line_id UUID;
  v_accepted_quantity_base NUMERIC(12,3);
  v_rejected_quantity_base NUMERIC(12,3);
  v_line_memo TEXT;
  v_ordered_total NUMERIC(12,3);
  v_accepted_total NUMERIC(12,3);
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_access_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  IF v_order.status NOT IN ('office_approved', 'ordered', 'partially_received') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_RECEIVABLE';
  END IF;

  INSERT INTO public.inventory_receipts (
    purchase_order_id,
    restaurant_id,
    supplier_id,
    received_by,
    status,
    memo
  )
  VALUES (
    p_purchase_order_id,
    v_order.restaurant_id,
    v_order.supplier_id,
    auth.uid(),
    'confirmed',
    NULLIF(btrim(COALESCE(p_memo, '')), '')
  )
  RETURNING id INTO v_receipt_id;

  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' AND jsonb_array_length(p_lines) > 0 THEN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
      v_line_id := NULLIF(v_line->>'line_id', '')::UUID;
      v_accepted_quantity_base := COALESCE(NULLIF(v_line->>'accepted_quantity_base', '')::NUMERIC, 0);
      v_rejected_quantity_base := COALESCE(NULLIF(v_line->>'rejected_quantity_base', '')::NUMERIC, 0);
      v_line_memo := NULLIF(btrim(COALESCE(v_line->>'memo', '')), '');

      INSERT INTO public.inventory_receipt_lines (
        receipt_id,
        purchase_order_line_id,
        product_id,
        received_quantity_base,
        accepted_quantity_base,
        rejected_quantity_base,
        memo
      )
      SELECT
        v_receipt_id,
        pol.id,
        pol.product_id,
        v_accepted_quantity_base + v_rejected_quantity_base,
        v_accepted_quantity_base,
        v_rejected_quantity_base,
        v_line_memo
      FROM public.inventory_purchase_order_lines pol
      WHERE pol.id = v_line_id
        AND pol.purchase_order_id = p_purchase_order_id;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_NOT_FOUND';
      END IF;
    END LOOP;
  ELSE
    INSERT INTO public.inventory_receipt_lines (
      receipt_id,
      purchase_order_line_id,
      product_id,
      received_quantity_base,
      accepted_quantity_base,
      rejected_quantity_base
    )
    SELECT
      v_receipt_id,
      pol.id,
      pol.product_id,
      GREATEST(pol.ordered_quantity_base - COALESCE(received.accepted_quantity_base, 0), 0),
      GREATEST(pol.ordered_quantity_base - COALESCE(received.accepted_quantity_base, 0), 0),
      0
    FROM public.inventory_purchase_order_lines pol
    LEFT JOIN (
      SELECT
        irl.purchase_order_line_id,
        SUM(irl.accepted_quantity_base) AS accepted_quantity_base
      FROM public.inventory_receipt_lines irl
      JOIN public.inventory_receipts ir
        ON ir.id = irl.receipt_id
       AND ir.status = 'confirmed'
      WHERE ir.purchase_order_id = p_purchase_order_id
      GROUP BY irl.purchase_order_line_id
    ) received
      ON received.purchase_order_line_id = pol.id
    WHERE pol.purchase_order_id = p_purchase_order_id
      AND GREATEST(pol.ordered_quantity_base - COALESCE(received.accepted_quantity_base, 0), 0) > 0;
  END IF;

  UPDATE public.inventory_items ii
  SET current_stock = COALESCE(current_stock, 0) + received.accepted_quantity_base,
      quantity = COALESCE(quantity, 0) + received.accepted_quantity_base,
      updated_at = now()
  FROM (
    SELECT
      ip.inventory_item_id,
      SUM(irl.accepted_quantity_base) AS accepted_quantity_base
    FROM public.inventory_receipt_lines irl
    JOIN public.inventory_products ip
      ON ip.id = irl.product_id
    WHERE irl.receipt_id = v_receipt_id
      AND ip.inventory_item_id IS NOT NULL
    GROUP BY ip.inventory_item_id
  ) received
  WHERE ii.id = received.inventory_item_id
    AND ii.restaurant_id = v_order.restaurant_id;

  INSERT INTO public.inventory_transactions (
    restaurant_id,
    ingredient_id,
    transaction_type,
    quantity_g,
    reference_type,
    reference_id,
    note,
    created_by
  )
  SELECT
    v_order.restaurant_id,
    ip.inventory_item_id,
    'restock',
    SUM(irl.accepted_quantity_base),
    'inventory_purchase_receipt',
    v_receipt_id,
    COALESCE(NULLIF(btrim(COALESCE(p_memo, '')), ''), 'Inventory purchase receipt'),
    auth.uid()
  FROM public.inventory_receipt_lines irl
  JOIN public.inventory_products ip
    ON ip.id = irl.product_id
  WHERE irl.receipt_id = v_receipt_id
    AND ip.inventory_item_id IS NOT NULL
    AND irl.accepted_quantity_base > 0
  GROUP BY ip.inventory_item_id;

  SELECT COALESCE(SUM(ordered_quantity_base), 0)
  INTO v_ordered_total
  FROM public.inventory_purchase_order_lines
  WHERE purchase_order_id = p_purchase_order_id;

  SELECT COALESCE(SUM(irl.accepted_quantity_base), 0)
  INTO v_accepted_total
  FROM public.inventory_receipt_lines irl
  JOIN public.inventory_receipts ir
    ON ir.id = irl.receipt_id
   AND ir.status = 'confirmed'
  WHERE ir.purchase_order_id = p_purchase_order_id;

  UPDATE public.inventory_purchase_orders
  SET status = CASE
        WHEN v_accepted_total >= v_ordered_total THEN 'received'
        ELSE 'partially_received'
      END,
      updated_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_order;

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.confirm_inventory_purchase_receipt(UUID, TEXT, JSONB) TO authenticated;
