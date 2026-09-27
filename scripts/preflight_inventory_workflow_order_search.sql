\set ON_ERROR_STOP on
BEGIN READ ONLY;
DO $preflight$
BEGIN
  IF to_regclass('public.inventory_purchase_orders') IS NULL
    OR to_regclass('public.inventory_purchase_order_lines') IS NULL
    OR to_regclass('public.inventory_products') IS NULL
    OR to_regclass('public.inventory_suppliers') IS NULL
    OR to_regprocedure('public.can_access_inventory_workflow(uuid)') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_WORKFLOW_ORDER_SEARCH_PREREQUISITE_MISSING';
  END IF;
  IF to_regprocedure('public.search_inventory_workflow_orders(uuid,text[],boolean,integer,integer,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'INVENTORY_WORKFLOW_ORDER_SEARCH_ALREADY_PRESENT';
  END IF;
END $preflight$;
ROLLBACK;
