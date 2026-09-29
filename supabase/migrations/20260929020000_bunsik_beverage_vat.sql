BEGIN;
SET LOCAL lock_timeout='5s';
-- Run with ordering paused after end-of-day close; deploy the VAT-capable client first.
LOCK TABLE public.orders,public.order_items,public.direct_order_requests,public.direct_order_request_items IN SHARE ROW EXCLUSIVE MODE;
CREATE TEMP TABLE beverage_vat_targets(store_id uuid,item_id uuid PRIMARY KEY,expected_name text,sugar_class text) ON COMMIT DROP;
INSERT INTO beverage_vat_targets VALUES
('8bc9eef5-dcd5-46b1-b931-23f77132322c','53249604-fd2e-40f5-a776-3e1bc5f32153','Coca-Cola','gt_5'),
('8bc9eef5-dcd5-46b1-b931-23f77132322c','4eda734f-4ac9-4f05-9eeb-0a4e4b122988','Strawberry Sting','gt_5'),
('8bc9eef5-dcd5-46b1-b931-23f77132322c','1917ec7d-c11e-4ed6-aced-c679d2104fba','Coca-Cola Zero','lte_5'),
('8bc9eef5-dcd5-46b1-b931-23f77132322c','8ce1a136-f51a-4ee6-a14e-73184a874646','Fanta Orange','lte_5'),
('8bc9eef5-dcd5-46b1-b931-23f77132322c','f14286a6-63c8-46c9-acb6-8cc518de0bfa','Sprite','lte_5'),
('3a268807-771f-4fd4-84fe-e1b0b00de40a','be7c2540-5a92-48bd-b2be-221652e5e09d','Coca-Cola','gt_5'),
('3a268807-771f-4fd4-84fe-e1b0b00de40a','d79cd51a-e09a-469c-a0ac-b1bf3a79a792','Strawberry Sting','gt_5'),
('3a268807-771f-4fd4-84fe-e1b0b00de40a','d8b74df7-e4ee-45b2-ada1-316121dcc64e','Coca-Cola Zero','lte_5'),
('3a268807-771f-4fd4-84fe-e1b0b00de40a','47790989-c0df-4340-b101-8eef975271f0','Fanta Orange','lte_5'),
('3a268807-771f-4fd4-84fe-e1b0b00de40a','8ab0ef6a-8452-4661-ae0b-3824a87b3a46','Sprite','lte_5');
SELECT m.id FROM public.menu_items m JOIN beverage_vat_targets t ON t.item_id=m.id FOR UPDATE OF m;
DO $$ BEGIN
 IF (SELECT count(*) FROM beverage_vat_targets t JOIN public.menu_items m ON m.id=t.item_id AND m.restaurant_id=t.store_id
     WHERE m.name_en=t.expected_name AND m.vat_category='food' AND NOT m.is_archived AND NOT m.is_combo
     AND m.beverage_sugar_tax_class='not_applicable' AND m.sugar_g_per_100ml IS NULL AND m.tax_basis_note IS NULL)<>10 THEN
   RAISE EXCEPTION 'BUNSIK_BEVERAGE_TARGET_DRIFT'; END IF;
 IF EXISTS(SELECT 1 FROM public.orders o JOIN (SELECT DISTINCT store_id FROM beverage_vat_targets) s ON s.store_id=o.restaurant_id
   WHERE o.status NOT IN ('completed','cancelled')) THEN RAISE EXCEPTION 'BUNSIK_BEVERAGE_OPEN_ORDERS'; END IF;
 -- Pending direct requests are immutable quotations. Preserve their pre-change
 -- tax snapshots instead of cancelling customer work during the catalogue switch.
 IF EXISTS(SELECT 1 FROM public.direct_order_requests r
   JOIN (SELECT DISTINCT store_id FROM beverage_vat_targets) s ON s.store_id=r.restaurant_id
   LEFT JOIN public.direct_order_request_items i ON i.request_id=r.id
   WHERE r.state IN ('awaiting_quote','quoted','awaiting_payment_review')
     AND (i.id IS NULL OR i.vat_profile_snapshot IS NULL)) THEN
   RAISE EXCEPTION 'BUNSIK_BEVERAGE_DIRECT_SNAPSHOT_REQUIRED'; END IF;
 PERFORM public.calculate_item_vat(i.vat_profile_snapshot,i.unit_price*i.quantity,'exclusive')
 FROM public.direct_order_requests r
 JOIN (SELECT DISTINCT store_id FROM beverage_vat_targets) s ON s.store_id=r.restaurant_id
 JOIN public.direct_order_request_items i ON i.request_id=r.id
 WHERE r.state IN ('awaiting_quote','quoted','awaiting_payment_review');
END $$;

CREATE TABLE public.bunsik_beverage_vat_20260929_backup AS
SELECT m.id,m.restaurant_id,m.beverage_sugar_tax_class,m.sugar_g_per_100ml,m.tax_basis_note,
 m.price,m.vat_category,t.sugar_class AS applied_class
FROM public.menu_items m JOIN beverage_vat_targets t ON t.item_id=m.id;
ALTER TABLE public.bunsik_beverage_vat_20260929_backup ADD PRIMARY KEY(id);
ALTER TABLE public.bunsik_beverage_vat_20260929_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.bunsik_beverage_vat_20260929_backup FROM PUBLIC,anon,authenticated,service_role;
UPDATE public.menu_items m SET beverage_sugar_tax_class=t.sugar_class,sugar_g_per_100ml=NULL,
 tax_basis_note='Store owner confirmed sold SKU sugar band on 2026-09-29; exact label grams pending.',updated_at=now()
FROM beverage_vat_targets t WHERE m.id=t.item_id AND m.restaurant_id=t.store_id;
INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
SELECT NULL,'bunsik_beverage_vat_correction','menu_items',m.id,
 jsonb_build_object('store_id',m.restaurant_id,'source','20260929020000_bunsik_beverage_vat',
 'old_values',to_jsonb(b),'new_values',jsonb_build_object('class',m.beverage_sugar_tax_class,'vat_rate',m.effective_vat_rate))
FROM public.menu_items m JOIN public.bunsik_beverage_vat_20260929_backup b ON b.id=m.id;
DO $$ BEGIN
 IF (SELECT count(*) FROM public.menu_items m JOIN beverage_vat_targets t ON t.item_id=m.id
    WHERE m.beverage_sugar_tax_class=t.sugar_class AND m.sugar_g_per_100ml IS NULL
     AND m.effective_vat_rate=CASE WHEN t.sugar_class='gt_5' THEN 10 ELSE 8 END)<>10 THEN
   RAISE EXCEPTION 'BUNSIK_BEVERAGE_POSTCONDITION_FAILED'; END IF;
END $$;
COMMIT;
