\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_rpc regprocedure := to_regprocedure(
    'public.set_order_wet_tissue_quantity(uuid,uuid,integer)'
  );
  v_rpc_definition text;
  v_item_type_check text;
  v_menu_item_check text;
  v_charge_check text;
BEGIN
  IF v_rpc IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_WET_TISSUE_RPC_MISSING';
  END IF;

  SELECT lower(pg_get_functiondef(v_rpc)) INTO v_rpc_definition;

  IF v_rpc_definition NOT LIKE '%security definer%'
     OR v_rpc_definition NOT LIKE '%p_quantity < 0 or p_quantity > 100%'
     OR v_rpc_definition NOT LIKE '%wet_tissue_after_payment%'
     OR v_rpc_definition NOT LIKE '%unit_price%3000%'
     OR v_rpc_definition NOT LIKE '%user_accessible_stores(auth.uid())%'
     OR v_rpc_definition NOT LIKE '%set_order_wet_tissue_quantity%' THEN
    RAISE EXCEPTION 'RESTAURANT_WET_TISSUE_RPC_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE oid = v_rpc AND prosecdef
  ) OR has_function_privilege('anon', v_rpc, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_rpc, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_rpc, 'EXECUTE') THEN
    RAISE EXCEPTION 'RESTAURANT_WET_TISSUE_RPC_PRIVILEGE_INVALID';
  END IF;

  SELECT lower(pg_get_constraintdef(oid))
  INTO v_item_type_check
  FROM pg_constraint
  WHERE conrelid = 'public.order_items'::regclass
    AND conname = 'order_items_item_type_check';

  SELECT lower(pg_get_constraintdef(oid))
  INTO v_menu_item_check
  FROM pg_constraint
  WHERE conrelid = 'public.order_items'::regclass
    AND conname = 'order_items_item_type_menu_item_check';

  SELECT lower(pg_get_constraintdef(oid))
  INTO v_charge_check
  FROM pg_constraint
  WHERE conrelid = 'public.order_items'::regclass
    AND conname = 'order_items_wet_tissue_charge_check';

  IF v_item_type_check NOT LIKE '%wet_tissue_charge%'
     OR v_menu_item_check NOT LIKE '%wet_tissue_charge%'
     OR v_charge_check NOT LIKE '%unit_price =%3000%'
     OR v_charge_check NOT LIKE '%quantity >= 1%'
     OR v_charge_check NOT LIKE '%quantity <= 100%' THEN
    RAISE EXCEPTION 'RESTAURANT_WET_TISSUE_CONSTRAINT_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'order_items'
      AND indexname = 'order_items_one_wet_tissue_charge_per_order_idx'
      AND lower(indexdef) LIKE '%unique index%'
      AND lower(indexdef) LIKE '%where (item_type = ''wet_tissue_charge''%'
  ) THEN
    RAISE EXCEPTION 'RESTAURANT_WET_TISSUE_UNIQUE_INDEX_INVALID';
  END IF;
END
$verify$;

SELECT 'restaurant wet-tissue charge verification passed' AS result;
