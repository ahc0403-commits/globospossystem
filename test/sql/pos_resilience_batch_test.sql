-- Functional call-count regression against real triggers, not source strings.
RESET ROLE;
BEGIN;
CREATE TEMP TABLE promotion_probe(order_id uuid);
ALTER FUNCTION public.sync_active_order_promotion(uuid,uuid,timestamptz)
 RENAME TO resilience_original_promotion;
CREATE FUNCTION public.sync_active_order_promotion(p_order_id uuid,p_store_id uuid,p_at timestamptz)
RETURNS public.order_discounts LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 INSERT INTO pg_temp.promotion_probe VALUES(p_order_id);
 RETURN public.resilience_original_promotion(p_order_id,p_store_id,p_at);
END $$;
REVOKE ALL ON FUNCTION public.sync_active_order_promotion(uuid,uuid,timestamptz) FROM PUBLIC,anon,authenticated,service_role;
UPDATE menu_discount_quantities SET remaining=NULL;
INSERT INTO orders(id,restaurant_id,order_source) VALUES
 ('30000000-0000-0000-0000-000000000088','10000000-0000-0000-0000-000000000001','qr');
TRUNCATE promotion_probe;
INSERT INTO order_items(id,restaurant_id,order_id,menu_item_id,unit_price,quantity)
SELECT gen_random_uuid(),'10000000-0000-0000-0000-000000000001',
 '30000000-0000-0000-0000-000000000088','40000000-0000-0000-0000-000000000001',100,1
FROM generate_series(1,100);
SELECT fixture_assert((SELECT count(*)=1 FROM promotion_probe),'100 inserted lines recompute one order once');
TRUNCATE promotion_probe;
UPDATE order_items SET quantity=quantity+1 WHERE order_id='30000000-0000-0000-0000-000000000088';
SELECT fixture_assert((SELECT count(*)=1 FROM promotion_probe),'100 updated lines recompute one order once');
TRUNCATE promotion_probe;
UPDATE order_items SET created_at=created_at WHERE order_id='30000000-0000-0000-0000-000000000088';
SELECT fixture_assert((SELECT count(*)=0 FROM promotion_probe),'unrelated updates do not recompute discounts');
DELETE FROM order_items WHERE order_id='30000000-0000-0000-0000-000000000088';
SELECT fixture_assert((SELECT count(*)=1 FROM promotion_probe),'100 deleted lines recompute one order once');

SELECT set_config('pos.quota_events','{}',true);
SELECT set_config('pos.quota_event_ids_v2','{}',true);
DELETE FROM pos_live_events WHERE source_table='menu_discount_quantities';
UPDATE menu_discount_quantities SET remaining=2 WHERE menu_item_id='40000000-0000-0000-0000-000000000001';
UPDATE menu_discount_quantities SET remaining=3 WHERE menu_item_id='40000000-0000-0000-0000-000000000002';
SELECT fixture_assert((SELECT count(*)=1 FROM pos_live_events WHERE source_table='menu_discount_quantities'),
 'quota writes in one transaction emit one compatible store invalidation');
ROLLBACK;
SELECT 'POS_RESILIENCE_BATCH_SQL=PASS';
