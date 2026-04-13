-- =============================================================================
-- Phase 2 Step 5 — Existing table extensions
-- Migration: 20260412200000_phase_2_step_5_existing_table_extensions.sql
-- Scope authority: stage1_scope_v1.3.md Appendix A.2
-- Target project: ynriuoomotxuwhuxxmhj (globospossystem)
-- Tables modified: restaurants, brands, menu_items, order_items, payments
-- Rules:
--   - No new tables (Step 4 done)
--   - No RLS policies (Step 6)
--   - No edge functions (Step 7)
--   - No process_payment RPC changes (Step 8)
--   - Surgical: touch only what scope A.2 specifies
--
-- Pre-migration audit findings:
--   restaurants: brand_id already exists (nullable, all 3 rows have value)
--                → just enforce NOT NULL + add tax_entity_id
--   brands:      brand_master_id missing → placeholder brand_master + backfill
--   order_items: item_type CHECK is ('standard','buffet_base','a_la_carte')
--                all 3 rows are 'standard', menu_item_id NOT NULL on all rows
--                → safe to migrate CHECK + values
--   payments:    unique_payment_per_order, payments_method_check,
--                service_payment_not_revenue all need dropping
--                method values: cash/card/pay/service → WeTax enum
-- =============================================================================

BEGIN;

-- ===========================================================================
-- 1. restaurants (stores) — brand_id NOT NULL + add tax_entity_id
-- ===========================================================================

-- 1a. Enforce NOT NULL on brand_id (all 3 existing rows already have a value)
ALTER TABLE public.restaurants ALTER COLUMN brand_id SET NOT NULL;

-- 1b. Insert placeholder tax_entity for dev data backfill
--     Predictable UUID: 00000000-0000-0000-0000-tex000000001
--     Real tax entities are created via onboarding flow (Step 7 wetax-onboarding).
INSERT INTO public.tax_entity (id, tax_code, name, owner_type, data_source)
VALUES (
  '00000000-0000-0000-0000-000000000011',
  'PLACEHOLDER_DEV_000',
  'GLOBOSVN Dev Placeholder (replace via onboarding)',
  'internal',
  'VNPT_EPAY'
);

-- 1c. Add tax_entity_id column (nullable first for backfill)
ALTER TABLE public.restaurants
  ADD COLUMN tax_entity_id uuid REFERENCES public.tax_entity(id);

-- 1d. Backfill all existing restaurants with placeholder
UPDATE public.restaurants
SET tax_entity_id = '00000000-0000-0000-0000-000000000011';

-- 1e. Enforce NOT NULL
ALTER TABLE public.restaurants
  ALTER COLUMN tax_entity_id SET NOT NULL;

COMMENT ON COLUMN public.restaurants.tax_entity_id IS 'Authoritative tax axis anchor (Invariant I1). Store reports to this tax_entity for WeTax dispatch. Dev rows use placeholder — replace with real tax_entity during onboarding (Step 7 wetax-onboarding).';
COMMENT ON COLUMN public.restaurants.brand_id IS 'FK to brands. NOT NULL enforced in Step 5 migration (all existing rows had values).';

-- ===========================================================================
-- 2. brands — brand_master_id (with placeholder) + service charge + tax hint
-- ===========================================================================

-- 2a. Insert placeholder brand_master (links to existing GLOBOSVN company)
INSERT INTO public.brand_master (id, company_id, name, type)
SELECT
  '00000000-0000-0000-0000-000000000012',
  id,
  'GLOBOSVN Internal',
  'internal'
FROM public.companies
LIMIT 1;

-- 2b. Add brand_master_id column (nullable first for backfill)
ALTER TABLE public.brands
  ADD COLUMN brand_master_id uuid REFERENCES public.brand_master(id);

-- 2c. Backfill all existing brands → placeholder brand_master
UPDATE public.brands
SET brand_master_id = '00000000-0000-0000-0000-000000000012';

-- 2d. Enforce NOT NULL
ALTER TABLE public.brands
  ALTER COLUMN brand_master_id SET NOT NULL;

-- 2e. Add remaining columns
ALTER TABLE public.brands
  ADD COLUMN suggested_tax_entity_id uuid REFERENCES public.tax_entity(id),
  ADD COLUMN service_charge_enabled  boolean     NOT NULL DEFAULT false,
  ADD COLUMN service_charge_rate     numeric(5,2) NOT NULL DEFAULT 0,
  ADD CONSTRAINT brands_service_charge_rate_check
    CHECK (service_charge_rate >= 0 AND service_charge_rate <= 20);

COMMENT ON COLUMN public.brands.brand_master_id IS 'FK to brand_master. Ownership grouping. Dev rows use placeholder — update with real brand_master during onboarding.';
COMMENT ON COLUMN public.brands.suggested_tax_entity_id IS 'UI default tax_entity for new stores under this brand. NOT authoritative — store.tax_entity_id is the authoritative source (Invariant I1).';
COMMENT ON COLUMN public.brands.service_charge_enabled IS 'Whether this brand applies a service charge to all orders. See scope v1.3 Section 3.1 service charge feature.';
COMMENT ON COLUMN public.brands.service_charge_rate IS 'Service charge percentage 0–20. Ignored when service_charge_enabled = false. Preserved when disabled for easy re-enable.';

-- ===========================================================================
-- 3. menu_items — add vat_category (backfill all existing → 'food')
-- ===========================================================================

ALTER TABLE public.menu_items
  ADD COLUMN vat_category text NOT NULL DEFAULT 'food'
    CHECK (vat_category IN ('food', 'alcohol'));

-- Existing 9 rows all get 'food' via DEFAULT.
-- Store owners must reclassify alcohol items manually after migration.

COMMENT ON COLUMN public.menu_items.vat_category IS 'VAT category for WeTax dispatch. food=8% VAT, alcohol=10% VAT. Required at item creation. Existing items defaulted to food — store owners must reclassify alcohol items manually.';

-- ===========================================================================
-- 4. order_items — migrate item_type + add VAT fields + display_name
-- ===========================================================================

-- 4a. Drop old item_type CHECK (values: standard / buffet_base / a_la_carte)
ALTER TABLE public.order_items
  DROP CONSTRAINT order_items_item_type_check;

-- 4b. Migrate existing item_type values → new WeTax vocabulary
--     standard / buffet_base / a_la_carte → all map to 'menu_item'
--     (they are all real menu lines, none are service_charge lines)
UPDATE public.order_items
SET item_type = 'menu_item'
WHERE item_type IN ('standard', 'buffet_base', 'a_la_carte');

-- 4c. Change column default to new value
ALTER TABLE public.order_items
  ALTER COLUMN item_type SET DEFAULT 'menu_item';

-- 4d. Add new item_type CHECK
ALTER TABLE public.order_items
  ADD CONSTRAINT order_items_item_type_check
  CHECK (item_type IN ('menu_item', 'service_charge'));

-- 4e. Add display_name (nullable first for backfill)
ALTER TABLE public.order_items ADD COLUMN display_name text;

-- 4f. Backfill display_name from menu_items.name via JOIN
--     Fallback chain: menu_items.name → label → 'Unknown Item'
UPDATE public.order_items oi
SET display_name = COALESCE(
  (SELECT mi.name FROM public.menu_items mi WHERE mi.id = oi.menu_item_id),
  oi.label,
  'Unknown Item'
);

-- 4g. Enforce NOT NULL on display_name
ALTER TABLE public.order_items ALTER COLUMN display_name SET NOT NULL;

-- 4h. Add CHECK linking item_type to menu_item_id presence
--     (all 3 existing rows: item_type='menu_item', menu_item_id NOT NULL → PASS)
ALTER TABLE public.order_items
  ADD CONSTRAINT order_items_item_type_menu_item_check
  CHECK (
    (item_type = 'menu_item'     AND menu_item_id IS NOT NULL) OR
    (item_type = 'service_charge' AND menu_item_id IS NULL)
  );

-- 4i. Add VAT fields (DEFAULT 0 for historical pre-WeTax rows — Invariant I11)
ALTER TABLE public.order_items
  ADD COLUMN vat_rate              numeric(5,2)  NOT NULL DEFAULT 0,
  ADD COLUMN vat_amount            numeric(15,2) NOT NULL DEFAULT 0,
  ADD COLUMN total_amount_ex_tax   numeric(15,2) NOT NULL DEFAULT 0,
  ADD COLUMN paying_amount_inc_tax numeric(15,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.order_items.item_type IS 'menu_item = real menu line; service_charge = virtual line inserted by process_payment for brand service charge (Step 8). Migrated from old values (standard/buffet_base/a_la_carte → menu_item).';
COMMENT ON COLUMN public.order_items.display_name IS 'Human-readable name snapshot at order creation. Copied from menu_items.name for menu lines; set to Service Charge (Food/Alcohol) for service_charge lines.';
COMMENT ON COLUMN public.order_items.vat_rate IS 'VAT rate snapshot at order creation (8.00=food, 10.00=alcohol). Immutable after order completes (Invariant I11). 0 for pre-WeTax historical rows.';
COMMENT ON COLUMN public.order_items.vat_amount IS 'VAT amount = total_amount_ex_tax × vat_rate / 100. Immutable after order completes (I11).';
COMMENT ON COLUMN public.order_items.total_amount_ex_tax IS 'Pre-tax line subtotal (unit_price × quantity − discount). Immutable after order completes (I11).';
COMMENT ON COLUMN public.order_items.paying_amount_inc_tax IS 'Total incl. VAT = total_amount_ex_tax + vat_amount. Immutable after order completes (I11).';

-- ===========================================================================
-- 5. payments — drop UNIQUE(order_id) + migrate method + add new fields
-- ===========================================================================

-- 5a. Drop UNIQUE(order_id) → enables hybrid payment (1 order : N payments)
ALTER TABLE public.payments DROP CONSTRAINT unique_payment_per_order;

-- 5b. Drop old method CHECK (values: cash/card/pay/service)
ALTER TABLE public.payments DROP CONSTRAINT payments_method_check;

-- 5c. Drop service-method-specific CHECK (references 'service' method which is being retired)
ALTER TABLE public.payments DROP CONSTRAINT service_payment_not_revenue;

-- 5d. Migrate existing method values to WeTax sendOrderInfo enum
--     cash    → CASH
--     card    → CREDITCARD
--     pay     → OTHER  (generic mobile pay — not enough info to classify further)
--     service → OTHER  (dev artifact; service charge is now an order_item, not a payment method)
UPDATE public.payments
SET method = CASE method
  WHEN 'cash'    THEN 'CASH'
  WHEN 'card'    THEN 'CREDITCARD'
  WHEN 'pay'     THEN 'OTHER'
  WHEN 'service' THEN 'OTHER'
  ELSE                'OTHER'
END;

-- 5e. Add new method CHECK aligned with WeTax sendOrderInfo enum
ALTER TABLE public.payments
  ADD CONSTRAINT payments_method_check
  CHECK (method IN (
    'CASH', 'CREDITCARD', 'ATM', 'MOMO', 'ZALOPAY',
    'VNPAY', 'SHOPEEPAY', 'BANKTRANSFER', 'VOUCHER', 'CREDITSALE', 'OTHER'
  ));

-- 5f. Add amount_portion — backfill from existing amount column
--     For pre-hybrid rows: amount_portion = amount (single payment covers full order)
ALTER TABLE public.payments ADD COLUMN amount_portion numeric(15,2);
UPDATE public.payments SET amount_portion = amount;
ALTER TABLE public.payments ALTER COLUMN amount_portion SET NOT NULL;
ALTER TABLE public.payments
  ADD CONSTRAINT payments_amount_portion_positive CHECK (amount_portion > 0);

-- 5g. Add proof photo fields
ALTER TABLE public.payments
  ADD COLUMN proof_photo_url      text,
  ADD COLUMN proof_photo_taken_at timestamptz,
  ADD COLUMN proof_photo_by       uuid REFERENCES public.users(id),
  ADD COLUMN proof_required       boolean NOT NULL DEFAULT false;

-- 5h. Add settlement fields
ALTER TABLE public.payments
  ADD COLUMN settlement_status   text NOT NULL DEFAULT 'pending'
    CHECK (settlement_status IN ('pending', 'reconciled', 'discrepancy')),
  ADD COLUMN settlement_batch_id uuid;

COMMENT ON COLUMN public.payments.method IS 'Payment method aligned with WeTax sendOrderInfo enum. Migrated from old values (cash→CASH, card→CREDITCARD, pay/service→OTHER).';
COMMENT ON COLUMN public.payments.amount_portion IS 'Portion of order total covered by this payment row. Backfilled = amount for pre-hybrid rows. Sum across order must equal orders.total_amount (Invariant I12).';
COMMENT ON COLUMN public.payments.proof_photo_url IS 'Supabase Storage URL of payment proof photo. Required when proof_required = true.';
COMMENT ON COLUMN public.payments.proof_photo_taken_at IS 'Timestamp when cashier captured the proof photo.';
COMMENT ON COLUMN public.payments.proof_photo_by IS 'FK to users. Cashier who captured the proof photo.';
COMMENT ON COLUMN public.payments.proof_required IS 'Whether a proof photo is required for this payment row. Set by business rules at payment creation.';
COMMENT ON COLUMN public.payments.settlement_status IS 'Reconciliation status: pending = not yet reviewed; reconciled = matched; discrepancy = mismatch requires review.';
COMMENT ON COLUMN public.payments.settlement_batch_id IS 'Links payment to a daily reconciliation batch (future table, Step 9+).';

COMMIT;
