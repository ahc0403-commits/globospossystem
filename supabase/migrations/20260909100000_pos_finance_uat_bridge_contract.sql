BEGIN;

-- production-gate: self-verifying
-- Additive POS -> Office Finance bridge contract. The non-fiscal SAMPLE legal
-- entity is the only external entity allowed through the Office store view.

CREATE OR REPLACE VIEW public.v_office_eligible_stores
WITH (security_invoker = true)
AS
SELECT
  store.id AS store_id,
  store.name AS store_name,
  store.address,
  store.is_active,
  store.tax_entity_id,
  entity.name AS tax_entity_name,
  entity.tax_code,
  store.brand_id,
  brand.code AS brand_code,
  brand.name AS brand_name
FROM public.restaurants store
JOIN public.tax_entity entity ON entity.id = store.tax_entity_id
JOIN public.brands brand ON brand.id = store.brand_id
JOIN public.tax_entity_brands entity_brand
  ON entity_brand.tax_entity_id = store.tax_entity_id
 AND entity_brand.brand_id = store.brand_id
WHERE entity.owner_type = 'internal'
   OR (
     store.id = '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
     AND store.name = 'BunsikClub SAMPLE'
     AND store.brand_id = 'a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878'::uuid
     AND entity.id = '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid
     AND entity.tax_code = 'PENDING_SAMPLE_STORE_TAX_PROFILE'
   );

COMMENT ON VIEW public.v_office_eligible_stores IS
  'Canonical Office bridge store source. Internal entities and only the exact non-fiscal BunsikClub SAMPLE entity are eligible.';

REVOKE ALL ON public.v_office_eligible_stores FROM PUBLIC, anon;
GRANT SELECT ON public.v_office_eligible_stores TO authenticated, service_role;

CREATE OR REPLACE VIEW public.v_office_confirmed_inventory_purchase_receipts
WITH (security_invoker = true)
AS
SELECT
  receipt.id AS receipt_id,
  receipt_line.id AS receipt_line_id,
  purchase.id AS purchase_order_id,
  purchase_line.id AS purchase_order_line_id,
  purchase.purchase_order_no,
  purchase.status AS order_status,
  receipt.status AS receipt_status,
  purchase.restaurant_id AS store_id,
  purchase.brand_id,
  store.tax_entity_id,
  purchase.supplier_id,
  supplier.supplier_name,
  receipt_line.product_id,
  receipt_line.accepted_quantity_base,
  receipt_line.final_supply_amount,
  receipt_line.final_tax_amount,
  receipt.total_amount AS receipt_header_total,
  receipt.received_by,
  receipt.verified_by,
  receipt.received_at,
  receipt.verified_at,
  purchase.updated_at AS purchase_order_updated_at,
  receipt.updated_at AS receipt_updated_at,
  receipt_line.updated_at AS receipt_line_updated_at,
  greatest(
    purchase.updated_at,
    receipt.updated_at,
    receipt_line.updated_at
  ) AS source_updated_at
FROM public.inventory_receipts receipt
JOIN public.inventory_purchase_orders purchase
  ON purchase.id = receipt.purchase_order_id
JOIN public.inventory_purchase_order_lines purchase_line
  ON purchase_line.purchase_order_id = purchase.id
JOIN public.inventory_receipt_lines receipt_line
  ON receipt_line.receipt_id = receipt.id
 AND receipt_line.purchase_order_line_id = purchase_line.id
JOIN public.inventory_suppliers supplier
  ON supplier.id = purchase.supplier_id
JOIN public.restaurants store
  ON store.id = purchase.restaurant_id
WHERE receipt.status = 'confirmed';

COMMENT ON VIEW public.v_office_confirmed_inventory_purchase_receipts IS
  'Service-role-only confirmed POS purchase receipts for the Office AP bridge, one row per receipt line.';

REVOKE ALL ON public.v_office_confirmed_inventory_purchase_receipts
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_office_confirmed_inventory_purchase_receipts
  TO service_role;

DO $verify$
DECLARE
  v_submit_definition text;
  v_store_definition text;
  v_brand_definition text;
  v_draft_definition text;
  v_verify_definition text;
  v_receipt_columns text[];
  v_expected_receipt_columns constant text[] := ARRAY[
    'receipt_id', 'receipt_line_id', 'purchase_order_id',
    'purchase_order_line_id', 'purchase_order_no', 'order_status',
    'receipt_status', 'store_id', 'brand_id', 'tax_entity_id',
    'supplier_id', 'supplier_name', 'product_id',
    'accepted_quantity_base', 'final_supply_amount', 'final_tax_amount',
    'receipt_header_total', 'received_by', 'verified_by', 'received_at',
    'verified_at', 'purchase_order_updated_at', 'receipt_updated_at',
    'receipt_line_updated_at', 'source_updated_at'
  ];
BEGIN
  IF to_regclass('public.v_office_eligible_stores') IS NULL
     OR to_regclass(
       'public.v_office_confirmed_inventory_purchase_receipts'
     ) IS NULL THEN
    RAISE EXCEPTION 'POS_FINANCE_UAT_BRIDGE_VIEW_MISSING';
  END IF;

  IF to_regprocedure(
       'public.submit_inventory_purchase_order(uuid,integer)'
     ) IS NULL
     OR to_regprocedure(
       'public.store_decide_inventory_purchase_order(uuid,integer,boolean,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.brand_decide_inventory_purchase_order(uuid,integer,boolean,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.upsert_inventory_receipt_draft_line(uuid,uuid,numeric,numeric,numeric,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.verify_inventory_receipt(uuid,integer,text,jsonb,text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'POS_FINANCE_UAT_PURCHASE_WORKFLOW_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.submit_inventory_purchase_order(uuid,integer)'::regprocedure
  ) INTO v_submit_definition;
  SELECT pg_get_functiondef(
    'public.store_decide_inventory_purchase_order(uuid,integer,boolean,text)'::regprocedure
  ) INTO v_store_definition;
  SELECT pg_get_functiondef(
    'public.brand_decide_inventory_purchase_order(uuid,integer,boolean,text)'::regprocedure
  ) INTO v_brand_definition;
  SELECT pg_get_functiondef(
    'public.upsert_inventory_receipt_draft_line(uuid,uuid,numeric,numeric,numeric,text)'::regprocedure
  ) INTO v_draft_definition;
  SELECT pg_get_functiondef(
    'public.verify_inventory_receipt(uuid,integer,text,jsonb,text)'::regprocedure
  ) INTO v_verify_definition;

  IF v_submit_definition NOT LIKE '%status = ''submitted''%'
     OR v_store_definition NOT LIKE '%INVENTORY_PURCHASE_SELF_APPROVAL_FORBIDDEN%'
     OR v_store_definition NOT LIKE '%THEN ''store_approved''%'
     OR v_brand_definition NOT LIKE '%INVENTORY_PURCHASE_SELF_APPROVAL_FORBIDDEN%'
     OR v_brand_definition NOT LIKE '%status = ''ordered''%'
     OR v_draft_definition NOT LIKE '%status, delivery_cycle%'
     OR v_draft_definition NOT LIKE '%''draft'', v_cycle%'
     OR v_verify_definition NOT LIKE '%INVENTORY_RECEIPT_MAKER_CHECKER_REQUIRED%'
     OR v_verify_definition NOT LIKE '%status = ''confirmed''%'
     OR v_verify_definition NOT LIKE '%THEN ''received'' ELSE ''partially_received''%' THEN
    RAISE EXCEPTION 'POS_FINANCE_UAT_PURCHASE_WORKFLOW_INVALID';
  END IF;

  SELECT array_agg(column_name ORDER BY ordinal_position)
  INTO v_receipt_columns
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'v_office_confirmed_inventory_purchase_receipts';
  IF v_receipt_columns IS DISTINCT FROM v_expected_receipt_columns THEN
    RAISE EXCEPTION 'POS_FINANCE_UAT_RECEIPT_COLUMNS_INVALID: %',
      v_receipt_columns;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.v_office_eligible_stores eligible
    WHERE eligible.store_id =
        '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
      AND eligible.store_name = 'BunsikClub SAMPLE'
      AND eligible.is_active
      AND eligible.brand_id =
        'a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878'::uuid
      AND eligible.tax_entity_id =
        '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid
  ) THEN
    RAISE EXCEPTION 'POS_FINANCE_UAT_SAMPLE_STORE_NOT_ELIGIBLE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_office_eligible_stores eligible
    JOIN public.tax_entity entity ON entity.id = eligible.tax_entity_id
    WHERE entity.owner_type = 'external'
      AND (
        eligible.store_id IS DISTINCT FROM
          '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
        OR eligible.tax_entity_id IS DISTINCT FROM
          '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid
      )
  ) THEN
    RAISE EXCEPTION 'POS_FINANCE_UAT_UNEXPECTED_EXTERNAL_STORE_ELIGIBLE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_receipts receipt
    WHERE receipt.status = 'confirmed'
      AND NOT EXISTS (
        SELECT 1
        FROM public.v_office_confirmed_inventory_purchase_receipts bridge
        WHERE bridge.receipt_id = receipt.id
      )
  ) THEN
    RAISE EXCEPTION 'POS_FINANCE_UAT_CONFIRMED_RECEIPT_NOT_EXPOSED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_office_confirmed_inventory_purchase_receipts bridge
    WHERE bridge.order_status NOT IN ('received', 'partially_received')
      OR bridge.accepted_quantity_base IS NULL
      OR bridge.final_supply_amount IS NULL
      OR bridge.final_tax_amount IS NULL
      OR bridge.receipt_header_total IS NULL
      OR NULLIF(btrim(bridge.supplier_name), '') IS NULL
      OR NULLIF(btrim(bridge.purchase_order_no), '') IS NULL
      OR bridge.store_id IS NULL
      OR bridge.brand_id IS NULL
      OR bridge.tax_entity_id IS NULL
      OR bridge.purchase_order_updated_at IS NULL
      OR bridge.receipt_updated_at IS NULL
      OR bridge.receipt_line_updated_at IS NULL
      OR bridge.source_updated_at IS NULL
  ) THEN
    RAISE EXCEPTION 'POS_FINANCE_UAT_CONFIRMED_RECEIPT_CONTRACT_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.v_office_confirmed_inventory_purchase_receipts bridge
    GROUP BY bridge.receipt_id, bridge.receipt_header_total
    HAVING abs(
      sum(bridge.final_supply_amount + bridge.final_tax_amount)
      - bridge.receipt_header_total
    ) > 0.01
  ) THEN
    RAISE EXCEPTION 'POS_FINANCE_UAT_RECEIPT_TOTAL_MISMATCH';
  END IF;

  IF has_table_privilege(
       'anon',
       'public.v_office_confirmed_inventory_purchase_receipts',
       'SELECT'
     )
     OR has_table_privilege(
       'authenticated',
       'public.v_office_confirmed_inventory_purchase_receipts',
       'SELECT'
     )
     OR NOT has_table_privilege(
       'service_role',
       'public.v_office_confirmed_inventory_purchase_receipts',
       'SELECT'
     ) THEN
    RAISE EXCEPTION 'POS_FINANCE_UAT_RECEIPT_VIEW_GRANTS_INVALID';
  END IF;
END;
$verify$;

COMMIT;
