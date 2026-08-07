DO $verify$
DECLARE
  v_rpc regprocedure := to_regprocedure(
    'public.set_order_wet_tissue_quantity(uuid,uuid,integer)'
  );
  v_definition text;
  v_constraint_validated boolean;
BEGIN
  IF v_rpc IS NULL THEN
    RAISE EXCEPTION 'WET_TISSUE_PRICE_2000_VERIFY_FAILED: RPC missing';
  END IF;

  SELECT pg_get_functiondef(v_rpc::oid) INTO v_definition;

  IF v_definition NOT LIKE '%v_total := 2000 * p_quantity%'
     OR v_definition NOT LIKE '%''unit_price'', 2000%'
     OR v_definition LIKE '%v_total := 3000 * p_quantity%' THEN
    RAISE EXCEPTION 'WET_TISSUE_PRICE_2000_VERIFY_FAILED: RPC price mismatch';
  END IF;

  SELECT constraint_row.convalidated
  INTO v_constraint_validated
  FROM pg_constraint constraint_row
  WHERE constraint_row.conrelid = 'public.order_items'::regclass
    AND constraint_row.conname = 'order_items_wet_tissue_charge_check';

  IF NOT COALESCE(v_constraint_validated, false) THEN
    RAISE EXCEPTION 'WET_TISSUE_PRICE_2000_VERIFY_FAILED: constraint mismatch';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.order_items item
    JOIN public.orders order_row ON order_row.id = item.order_id
    WHERE item.item_type = 'wet_tissue_charge'
      AND order_row.status NOT IN ('completed', 'cancelled')
      AND NOT EXISTS (
        SELECT 1
        FROM public.payments payment
        WHERE payment.order_id = item.order_id
          AND payment.restaurant_id = item.restaurant_id
      )
      AND item.unit_price <> 2000
  ) THEN
    RAISE EXCEPTION 'WET_TISSUE_PRICE_2000_VERIFY_FAILED: active price mismatch';
  END IF;
END;
$verify$;
