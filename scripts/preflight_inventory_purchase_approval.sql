\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.inventory_purchase_orders') IS NULL
     OR to_regclass('public.inventory_purchase_order_lines') IS NULL
     OR to_regclass('public.inventory_receipts') IS NULL
     OR to_regclass('public.inventory_receipt_lines') IS NULL
     OR to_regclass('public.inventory_supplier_items') IS NULL
     OR to_regclass('public.inventory_transactions') IS NULL
     OR to_regclass('public.store_fixed_account_requirements') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_APPROVAL_BASE_TABLES_MISSING';
  END IF;

  IF to_regprocedure(
       'public.create_manual_inventory_purchase_order(uuid,uuid,jsonb,date,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.recalculate_inventory_purchase_order_totals(uuid)'
     ) IS NULL
     OR to_regprocedure('public.can_access_inventory_purchase_store(uuid)')
       IS NULL
     OR to_regprocedure('public.require_workforce_manager(uuid)') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_APPROVAL_BASE_FUNCTIONS_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'users'
      AND column_name = 'account_type'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurants'
      AND column_name = 'short_code'
  ) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_WORKFORCE_BASE_MISSING';
  END IF;
END;
$preflight$;

SELECT 'inventory purchase approval preflight passed' AS result;
