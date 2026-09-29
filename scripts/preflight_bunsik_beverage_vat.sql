\set ON_ERROR_STOP on
BEGIN;
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
SELECT m.restaurant_id,m.id,m.name_en,m.beverage_sugar_tax_class AS old_class,t.sugar_class AS new_class,
 m.effective_vat_rate AS old_vat,CASE WHEN t.sugar_class='gt_5' THEN 10 ELSE 8 END AS new_vat
 FROM public.menu_items m JOIN beverage_vat_targets t ON t.item_id=m.id ORDER BY m.restaurant_id,m.name_en;
ROLLBACK;
