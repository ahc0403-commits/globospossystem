\set ON_ERROR_STOP on
BEGIN READ ONLY;
DO $verify$
DECLARE definition text;
BEGIN
  IF to_regprocedure('public.get_inventory_workflow_orders(uuid,text[],boolean,integer,integer)') IS NULL
    OR to_regprocedure('public.get_inventory_workflow_detail(uuid)') IS NULL
    OR to_regprocedure('public.submit_inventory_receipt_batch(uuid,uuid,integer,integer,text,jsonb,text,text,text,date,text)') IS NULL
    OR to_regprocedure('public.urgent_approve_inventory_purchase_order(uuid,integer,text)') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_WORKFLOW_API_MISSING'; END IF;
  SELECT pg_get_functiondef('public.store_decide_inventory_purchase_order(uuid,integer,boolean,text)'::regprocedure) INTO definition;
  IF definition LIKE '%INVENTORY_PURCHASE_SELF_APPROVAL_FORBIDDEN%' THEN
    RAISE EXCEPTION 'INVENTORY_STORE_CREATOR_STILL_BLOCKED'; END IF;
  SELECT pg_get_functiondef('public.brand_decide_inventory_purchase_order(uuid,integer,boolean,text)'::regprocedure) INTO definition;
  IF definition LIKE '%INVENTORY_PURCHASE_SELF_APPROVAL_FORBIDDEN%'
    OR definition NOT LIKE '%INVENTORY_PURCHASE_DISTINCT_APPROVER_REQUIRED%'
    OR definition NOT LIKE '%extensions.digest%' THEN RAISE EXCEPTION 'INVENTORY_BRAND_APPROVAL_CONTRACT_INVALID'; END IF;
  SELECT pg_get_functiondef('public.verify_inventory_receipt(uuid,integer,text,jsonb,text)'::regprocedure) INTO definition;
  IF definition NOT LIKE '%INVENTORY_RECEIPT_MAKER_CHECKER_REQUIRED%'
    OR definition NOT LIKE '%validate_inventory_receipt_attachment%'
    OR definition NOT LIKE '%UPDATE public.inventory_items%' THEN
    RAISE EXCEPTION 'INVENTORY_ACCOUNTING_GATE_INVALID'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='public'
    AND tablename='inventory_supplier_items' AND policyname='inventory_supplier_items_master_only'
    AND permissive='RESTRICTIVE') THEN RAISE EXCEPTION 'INVENTORY_MASTER_PRICE_GUARD_MISSING'; END IF;
  IF has_function_privilege('anon','public.submit_inventory_receipt_batch(uuid,uuid,integer,integer,text,jsonb,text,text,text,date,text)','EXECUTE') THEN
    RAISE EXCEPTION 'INVENTORY_WORKFLOW_ANONYMOUS_ACCESS'; END IF;
END $verify$;
-- All active stores, without a pilot-only ID/name filter.
SELECT r.id AS store_id,r.name,r.brand_id,r.tax_entity_id,
  'common_role_policy' AS application_scope
FROM public.restaurants r WHERE r.is_active ORDER BY r.name;
SELECT 'inventory workflow schema verified; per-store live UAT remains a separate gate' AS result;
ROLLBACK;
