SET ROLE authenticated;
SELECT set_config(
  'request.jwt.claim.sub',
  '40000000-0000-0000-0000-000000000001',
  false
);
SELECT set_config('request.jwt.claim.role', 'authenticated', false);

DO $$
BEGIN
  IF NOT public.can_read_inventory_purchase_store(
    '10000000-0000-0000-0000-000000000001'
  ) THEN
    RAISE EXCEPTION 'ORDERER_OWN_STORE_READ_DENIED';
  END IF;
  IF public.can_read_inventory_purchase_store(
    '10000000-0000-0000-0000-000000000002'
  ) THEN
    RAISE EXCEPTION 'ORDERER_OTHER_STORE_READ_ALLOWED';
  END IF;
  IF public.can_access_inventory_purchase_store(
    '10000000-0000-0000-0000-000000000001'
  ) THEN
    RAISE EXCEPTION 'ORDERER_MASTER_ACCESS_ALLOWED';
  END IF;
  IF NOT public.can_create_inventory_purchase_order(
    '10000000-0000-0000-0000-000000000001'
  ) THEN
    RAISE EXCEPTION 'ORDERER_CREATE_DENIED';
  END IF;
  IF public.can_verify_inventory_receipt(
    '10000000-0000-0000-0000-000000000001'
  ) THEN
    RAISE EXCEPTION 'ORDERER_VERIFY_ALLOWED';
  END IF;
  IF (SELECT count(*) FROM public.inventory_products) <> 1 THEN
    RAISE EXCEPTION 'ORDERER_PRODUCT_SCOPE_INVALID';
  END IF;
  IF (SELECT count(*) FROM public.inventory_supplier_items) <> 1 THEN
    RAISE EXCEPTION 'ORDERER_SUPPLIER_ITEM_SCOPE_INVALID';
  END IF;
  IF (SELECT count(*) FROM public.inventory_purchase_orders) <> 1 THEN
    RAISE EXCEPTION 'ORDERER_PURCHASE_ORDER_SCOPE_INVALID';
  END IF;
END;
$$;

SELECT set_config(
  'request.jwt.claim.sub',
  '40000000-0000-0000-0000-000000000002',
  false
);
DO $$
BEGIN
  IF NOT public.can_read_inventory_purchase_store(
    '10000000-0000-0000-0000-000000000001'
  ) THEN
    RAISE EXCEPTION 'ACCOUNTING_OWN_STORE_READ_DENIED';
  END IF;
  IF public.can_create_inventory_purchase_order(
    '10000000-0000-0000-0000-000000000001'
  ) THEN
    RAISE EXCEPTION 'ACCOUNTING_CREATE_ALLOWED';
  END IF;
  IF NOT public.can_verify_inventory_receipt(
    '10000000-0000-0000-0000-000000000001'
  ) THEN
    RAISE EXCEPTION 'ACCOUNTING_VERIFY_DENIED';
  END IF;
END;
$$;

SELECT set_config(
  'request.jwt.claim.sub',
  '40000000-0000-0000-0000-000000000003',
  false
);
DO $$
BEGIN
  IF NOT public.can_access_inventory_purchase_store(
    '10000000-0000-0000-0000-000000000001'
  ) THEN
    RAISE EXCEPTION 'MANAGER_MASTER_ACCESS_DENIED';
  END IF;
  IF NOT public.can_create_inventory_purchase_order(
    '10000000-0000-0000-0000-000000000001'
  ) THEN
    RAISE EXCEPTION 'MANAGER_CREATE_DENIED';
  END IF;
END;
$$;

SELECT set_config(
  'request.jwt.claim.sub',
  '40000000-0000-0000-0000-000000000004',
  false
);
DO $$
BEGIN
  IF public.can_read_inventory_purchase_store(
    '10000000-0000-0000-0000-000000000001'
  ) OR public.can_access_inventory_purchase_store(
    '10000000-0000-0000-0000-000000000001'
  ) THEN
    RAISE EXCEPTION 'UNRELATED_ROLE_PURCHASE_ACCESS_ALLOWED';
  END IF;
END;
$$;

RESET ROLE;

DO $$
DECLARE
  v_blocked boolean := false;
BEGIN
  BEGIN
    INSERT INTO public.inventory_purchase_order_lines(
      id, purchase_order_id, product_id, supplier_item_id
    ) VALUES (
      '90000000-0000-0000-0000-000000000001',
      '80000000-0000-0000-0000-000000000001',
      '60000000-0000-0000-0000-000000000002',
      '70000000-0000-0000-0000-000000000002'
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%INVENTORY_PURCHASE_SUPPLIER_ITEM_SCOPE_INVALID%' THEN
      v_blocked := true;
    ELSE
      RAISE;
    END IF;
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'CROSS_STORE_SUPPLIER_ITEM_ALLOWED';
  END IF;

  INSERT INTO public.inventory_purchase_order_lines(
    id, purchase_order_id, product_id, supplier_item_id
  ) VALUES (
    '90000000-0000-0000-0000-000000000002',
    '80000000-0000-0000-0000-000000000001',
    '60000000-0000-0000-0000-000000000001',
    '70000000-0000-0000-0000-000000000001'
  );
END;
$$;

SELECT 'PASS: inventory purchase orderer catalog access';
