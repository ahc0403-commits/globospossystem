BEGIN;

-- ===========================================================================
-- 1. restaurants — brand_id NOT NULL + add tax_entity_id
-- ===========================================================================
ALTER TABLE public.restaurants ALTER COLUMN brand_id SET NOT NULL;

INSERT INTO public.tax_entity (id, tax_code, name, owner_type, data_source)
VALUES (
  '00000000-0000-0000-0000-000000000011',
  'PLACEHOLDER_DEV_000',
  'GLOBOSVN Dev Placeholder (replace via onboarding)',
  'internal',
  'VNPT_EPAY'
);

ALTER TABLE public.restaurants ADD COLUMN tax_entity_id uuid REFERENCES public.tax_entity(id);
UPDATE public.restaurants SET tax_entity_id = '00000000-0000-0000-0000-000000000011';
ALTER TABLE public.restaurants ALTER COLUMN tax_entity_id SET NOT NULL;

COMMENT ON COLUMN public.restaurants.tax_entity_id IS 'Authoritative tax axis anchor (Invariant I1). Dev rows use placeholder — replace with real tax_entity during onboarding.';
COMMENT ON COLUMN public.restaurants.brand_id IS 'FK to brands. NOT NULL enforced in Step 5 (all existing rows had values).';

-- ===========================================================================
-- 2. brands — brand_master_id + service charge + tax hint
-- ===========================================================================
INSERT INTO public.brand_master (id, company_id, name, type)
SELECT '00000000-0000-0000-0000-000000000012', id, 'GLOBOSVN Internal', 'internal'
FROM public.companies LIMIT 1;

ALTER TABLE public.brands ADD COLUMN brand_master_id uuid REFERENCES public.brand_master(id);
UPDATE public.brands SET brand_master_id = '00000000-0000-0000-0000-000000000012';
ALTER TABLE public.brands ALTER COLUMN brand_master_id SET NOT NULL;

ALTER TABLE public.brands
  ADD COLUMN suggested_tax_entity_id uuid REFERENCES public.tax_entity(id),
  ADD COLUMN service_charge_enabled  boolean      NOT NULL DEFAULT false,
  ADD COLUMN service_charge_rate     numeric(5,2) NOT NULL DEFAULT 0,
  ADD CONSTRAINT brands_service_charge_rate_check
    CHECK (service_charge_rate >= 0 AND service_charge_rate <= 20);

COMMENT ON COLUMN public.brands.brand_master_id IS 'FK to brand_master. Dev rows use placeholder — update during onboarding.';
COMMENT ON COLUMN public.brands.suggested_tax_entity_id IS 'UI default tax_entity for new stores under this brand. NOT authoritative — store.tax_entity_id is authoritative (Invariant I1).';
COMMENT ON COLUMN public.brands.service_charge_enabled IS 'Whether this brand applies a service charge to all orders.';
COMMENT ON COLUMN public.brands.service_charge_rate IS 'Service charge percentage 0–20. Ignored when service_charge_enabled = false.';

-- ===========================================================================
-- 3. menu_items — add vat_category
-- ===========================================================================
ALTER TABLE public.menu_items
  ADD COLUMN vat_category text NOT NULL DEFAULT 'food'
    CHECK (vat_category IN ('food', 'alcohol'));

COMMENT ON COLUMN public.menu_items.vat_category IS 'VAT category. food=8%, alcohol=10%. Existing items defaulted to food — store owners must reclassify alcohol items manually.';

-- ===========================================================================
-- 4. order_items — migrate item_type + add VAT fields + display_name
-- ===========================================================================
ALTER TABLE public.order_items DROP CONSTRAINT order_items_item_type_check;

UPDATE public.order_items SET item_type = 'menu_item'
WHERE item_type IN ('standard', 'buffet_base', 'a_la_carte');

ALTER TABLE public.order_items ALTER COLUMN item_type SET DEFAULT 'menu_item';

ALTER TABLE public.order_items
  ADD CONSTRAINT order_items_item_type_check
  CHECK (item_type IN ('menu_item', 'service_charge'));

ALTER TABLE public.order_items ADD COLUMN display_name text;

UPDATE public.order_items oi
SET display_name = COALESCE(
  (SELECT mi.name FROM public.menu_items mi WHERE mi.id = oi.menu_item_id),
  oi.label,
  'Unknown Item'
);

ALTER TABLE public.order_items ALTER COLUMN display_name SET NOT NULL;

ALTER TABLE public.order_items
  ADD CONSTRAINT order_items_item_type_menu_item_check
  CHECK (
    (item_type = 'menu_item'      AND menu_item_id IS NOT NULL) OR
    (item_type = 'service_charge' AND menu_item_id IS NULL)
  );

ALTER TABLE public.order_items
  ADD COLUMN vat_rate              numeric(5,2)  NOT NULL DEFAULT 0,
  ADD COLUMN vat_amount            numeric(15,2) NOT NULL DEFAULT 0,
  ADD COLUMN total_amount_ex_tax   numeric(15,2) NOT NULL DEFAULT 0,
  ADD COLUMN paying_amount_inc_tax numeric(15,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.order_items.item_type IS 'menu_item = real menu line; service_charge = virtual line for brand service charge (Step 8). Migrated from standard/buffet_base/a_la_carte → menu_item.';
COMMENT ON COLUMN public.order_items.display_name IS 'Human-readable name snapshot at order creation. Backfilled from menu_items.name.';
COMMENT ON COLUMN public.order_items.vat_rate IS 'VAT rate snapshot at order creation (8.00 food, 10.00 alcohol). Immutable after completion (Invariant I11). 0 for pre-WeTax rows.';
COMMENT ON COLUMN public.order_items.vat_amount IS 'VAT amount = total_amount_ex_tax × vat_rate / 100. Immutable (I11).';
COMMENT ON COLUMN public.order_items.total_amount_ex_tax IS 'Pre-tax line subtotal. Immutable (I11).';
COMMENT ON COLUMN public.order_items.paying_amount_inc_tax IS 'Total incl. VAT. Immutable (I11).';

-- ===========================================================================
-- 5. payments — drop UNIQUE + migrate method + new fields
-- ===========================================================================
ALTER TABLE public.payments DROP CONSTRAINT unique_payment_per_order;
ALTER TABLE public.payments DROP CONSTRAINT payments_method_check;
ALTER TABLE public.payments DROP CONSTRAINT service_payment_not_revenue;

UPDATE public.payments SET method = CASE method
  WHEN 'cash'    THEN 'CASH'
  WHEN 'card'    THEN 'CREDITCARD'
  WHEN 'pay'     THEN 'OTHER'
  WHEN 'service' THEN 'OTHER'
  ELSE                'OTHER'
END;

ALTER TABLE public.payments
  ADD CONSTRAINT payments_method_check
  CHECK (method IN (
    'CASH','CREDITCARD','ATM','MOMO','ZALOPAY',
    'VNPAY','SHOPEEPAY','BANKTRANSFER','VOUCHER','CREDITSALE','OTHER'
  ));

ALTER TABLE public.payments ADD COLUMN amount_portion numeric(15,2);
UPDATE public.payments SET amount_portion = amount;
ALTER TABLE public.payments ALTER COLUMN amount_portion SET NOT NULL;
ALTER TABLE public.payments
  ADD CONSTRAINT payments_amount_portion_positive CHECK (amount_portion > 0);

ALTER TABLE public.payments
  ADD COLUMN proof_photo_url      text,
  ADD COLUMN proof_photo_taken_at timestamptz,
  ADD COLUMN proof_photo_by       uuid REFERENCES public.users(id),
  ADD COLUMN proof_required       boolean NOT NULL DEFAULT false;

ALTER TABLE public.payments
  ADD COLUMN settlement_status   text NOT NULL DEFAULT 'pending'
    CHECK (settlement_status IN ('pending', 'reconciled', 'discrepancy')),
  ADD COLUMN settlement_batch_id uuid;

COMMENT ON COLUMN public.payments.method IS 'Payment method aligned with WeTax sendOrderInfo enum. Migrated from old values (cash→CASH, card→CREDITCARD, pay/service→OTHER).';
COMMENT ON COLUMN public.payments.amount_portion IS 'Portion of order total covered by this row. Backfilled = amount for pre-hybrid rows. Sum per order must equal orders.total_amount (Invariant I12).';
COMMENT ON COLUMN public.payments.proof_photo_url IS 'Supabase Storage URL of payment proof photo.';
COMMENT ON COLUMN public.payments.proof_photo_taken_at IS 'Timestamp when cashier captured the proof photo.';
COMMENT ON COLUMN public.payments.proof_photo_by IS 'FK to users. Cashier who captured the proof photo.';
COMMENT ON COLUMN public.payments.proof_required IS 'Whether a proof photo is required for this payment row.';
COMMENT ON COLUMN public.payments.settlement_status IS 'Reconciliation status: pending / reconciled / discrepancy.';
COMMENT ON COLUMN public.payments.settlement_batch_id IS 'Links to daily reconciliation batch (future table).';

COMMIT;;
