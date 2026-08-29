\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_verify regprocedure := to_regprocedure(
    'public.verify_inventory_receipt(uuid,integer,text,jsonb,text)'
  );
  v_draft regprocedure := to_regprocedure(
    'public.upsert_inventory_receipt_draft_line(uuid,uuid,numeric,numeric,numeric,text)'
  );
  v_legacy regprocedure := to_regprocedure(
    'public.confirm_inventory_purchase_receipt(uuid,text,jsonb)'
  );
  v_verify_definition text;
  v_verify_access_definition text;
  v_brand_definition text;
  v_draft_definition text;
  v_legacy_definition text;
  v_store_scope_definition text;
BEGIN
  IF to_regclass('public.inventory_purchase_approval_events') IS NULL
     OR to_regclass('public.inventory_purchase_documents') IS NULL
     OR to_regclass('public.inventory_supplier_item_price_history') IS NULL
     OR to_regclass('public.user_tax_entity_access') IS NULL
     OR to_regclass('public.legal_entity_fixed_account_requirements') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_APPROVAL_TABLES_MISSING';
  END IF;

  IF v_verify IS NULL OR v_draft IS NULL OR v_legacy IS NULL
     OR to_regprocedure(
       'public.save_inventory_purchase_order_draft(uuid,integer,date,text,jsonb)'
     ) IS NULL
     OR to_regprocedure(
       'public.store_decide_inventory_purchase_order(uuid,integer,boolean,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.brand_decide_inventory_purchase_order(uuid,integer,boolean,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.bulk_update_inventory_supplier_prices(uuid,jsonb,boolean)'
     ) IS NULL
     OR to_regprocedure(
       'public.admin_configure_legal_entity_inventory_accounting(uuid,text,text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_APPROVAL_FUNCTIONS_MISSING';
  END IF;

  SELECT pg_get_functiondef(v_verify) INTO v_verify_definition;
  SELECT pg_get_functiondef(
    'public.can_verify_inventory_receipt(uuid)'::regprocedure
  ) INTO v_verify_access_definition;
  SELECT pg_get_functiondef(
    'public.brand_decide_inventory_purchase_order(uuid,integer,boolean,text)'::regprocedure
  ) INTO v_brand_definition;
  SELECT pg_get_functiondef(v_draft) INTO v_draft_definition;
  SELECT pg_get_functiondef(v_legacy) INTO v_legacy_definition;
  SELECT pg_get_functiondef(
    'public.user_accessible_stores(uuid)'::regprocedure
  ) INTO v_store_scope_definition;
  IF v_verify_definition NOT LIKE '%INVENTORY_RECEIPT_MAKER_CHECKER_REQUIRED%'
     OR v_verify_definition NOT LIKE '%UPDATE public.inventory_items%'
     OR v_verify_definition NOT LIKE '%INSERT INTO public.inventory_transactions%'
     OR v_draft_definition LIKE '%UPDATE public.inventory_items%'
     OR v_draft_definition LIKE '%INSERT INTO public.inventory_transactions%'
     OR v_legacy_definition NOT LIKE
       '%INVENTORY_RECEIPT_DRAFT_AND_VERIFIER_REQUIRED%'
     OR v_verify_access_definition NOT LIKE '%inventory_accounting%'
     OR v_store_scope_definition NOT LIKE '%user_tax_entity_access%'
     OR v_brand_definition NOT LIKE '%status = ''ordered''%' THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_STOCK_GATE_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.store_fixed_account_requirements
    WHERE account_type = 'inventory_accounting'
  ) THEN
    RAISE EXCEPTION 'INVENTORY_ACCOUNTING_MUST_NOT_BE_STORE_SCOPED';
  END IF;

  IF has_function_privilege('anon', v_verify, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_verify, 'EXECUTE') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_APPROVAL_PRIVILEGES_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'inventory_purchase_orders'
      AND c.contype = 'c'
      AND pg_get_constraintdef(c.oid) LIKE '%store_approved%'
      AND pg_get_constraintdef(c.oid) LIKE '%brand_approved%'
  ) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_APPROVAL_STATUS_CONSTRAINT_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM storage.buckets
    WHERE id = 'inventory-purchase-documents' AND public = false
  ) OR NOT EXISTS (
    SELECT 1 FROM storage.buckets
    WHERE id = 'inventory-receipt-statements' AND public = false
  ) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_DOCUMENT_BUCKET_INVALID';
  END IF;
END;
$verify$;

SELECT 'inventory purchase approval verification passed' AS result;
