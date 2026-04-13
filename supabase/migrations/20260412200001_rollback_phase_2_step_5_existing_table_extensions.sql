-- =============================================================================
-- Phase 2 Step 5 — ROLLBACK (manual apply only, NOT in chain)
-- Reverses: 20260412200000_phase_2_step_5_existing_table_extensions.sql
-- WARNING: Drops columns and restores old CHECKs. Data loss on new columns.
-- =============================================================================

BEGIN;

-- payments: restore
ALTER TABLE public.payments DROP CONSTRAINT IF EXISTS payments_method_check;
ALTER TABLE public.payments DROP CONSTRAINT IF EXISTS payments_amount_portion_positive;
ALTER TABLE public.payments DROP COLUMN IF EXISTS settlement_batch_id;
ALTER TABLE public.payments DROP COLUMN IF EXISTS settlement_status;
ALTER TABLE public.payments DROP COLUMN IF EXISTS proof_required;
ALTER TABLE public.payments DROP COLUMN IF EXISTS proof_photo_by;
ALTER TABLE public.payments DROP COLUMN IF EXISTS proof_photo_taken_at;
ALTER TABLE public.payments DROP COLUMN IF EXISTS proof_photo_url;
ALTER TABLE public.payments DROP COLUMN IF EXISTS amount_portion;
UPDATE public.payments SET method = CASE method
  WHEN 'CASH'       THEN 'cash'
  WHEN 'CREDITCARD' THEN 'card'
  ELSE                   'pay'
END;
ALTER TABLE public.payments ADD CONSTRAINT payments_method_check
  CHECK (method = ANY (ARRAY['cash','card','pay','service']));
ALTER TABLE public.payments ADD CONSTRAINT service_payment_not_revenue
  CHECK ((method <> 'service') OR (is_revenue = false));
ALTER TABLE public.payments ADD CONSTRAINT unique_payment_per_order UNIQUE (order_id);

-- order_items: restore
ALTER TABLE public.order_items DROP CONSTRAINT IF EXISTS order_items_item_type_check;
ALTER TABLE public.order_items DROP CONSTRAINT IF EXISTS order_items_item_type_menu_item_check;
ALTER TABLE public.order_items DROP COLUMN IF EXISTS paying_amount_inc_tax;
ALTER TABLE public.order_items DROP COLUMN IF EXISTS total_amount_ex_tax;
ALTER TABLE public.order_items DROP COLUMN IF EXISTS vat_amount;
ALTER TABLE public.order_items DROP COLUMN IF EXISTS vat_rate;
ALTER TABLE public.order_items DROP COLUMN IF EXISTS display_name;
UPDATE public.order_items SET item_type = 'standard' WHERE item_type = 'menu_item';
ALTER TABLE public.order_items ALTER COLUMN item_type SET DEFAULT 'standard';
ALTER TABLE public.order_items ADD CONSTRAINT order_items_item_type_check
  CHECK (item_type = ANY (ARRAY['standard','buffet_base','a_la_carte']));

-- menu_items: restore
ALTER TABLE public.menu_items DROP COLUMN IF EXISTS vat_category;

-- brands: restore
ALTER TABLE public.brands DROP CONSTRAINT IF EXISTS brands_service_charge_rate_check;
ALTER TABLE public.brands DROP COLUMN IF EXISTS service_charge_rate;
ALTER TABLE public.brands DROP COLUMN IF EXISTS service_charge_enabled;
ALTER TABLE public.brands DROP COLUMN IF EXISTS suggested_tax_entity_id;
ALTER TABLE public.brands DROP COLUMN IF EXISTS brand_master_id;

-- restaurants: restore
ALTER TABLE public.restaurants DROP COLUMN IF EXISTS tax_entity_id;
ALTER TABLE public.restaurants ALTER COLUMN brand_id DROP NOT NULL;

-- Clean up placeholder data
DELETE FROM public.tax_entity WHERE id = '00000000-0000-0000-0000-000000000011';
DELETE FROM public.brand_master WHERE id = '00000000-0000-0000-0000-000000000012';

COMMIT;
