-- Synthetic order-time reservation and discount integration regression.
SELECT set_config('request.jwt.claim.sub','20000000-0000-0000-0000-000000000001',false);
INSERT INTO restaurants(id) VALUES('10000000-0000-0000-0000-000000000001'),('10000000-0000-0000-0000-000000000002');
INSERT INTO tables VALUES('70000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','1','1F');
INSERT INTO menu_categories VALUES('80000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Existing discount','기존 할인','Ưu đãi','Discount',0,true);
INSERT INTO table_qr_tokens VALUES('fixture','10000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001',true);
INSERT INTO menu_items(id,restaurant_id) VALUES
 ('40000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001'),
 ('40000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001'),
 ('40000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000002');
INSERT INTO orders(id,restaurant_id,order_source) VALUES
 ('30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','qr'),
 ('30000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','qr'),
 ('30000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','qr');
INSERT INTO store_promotions(id,restaurant_id,name,discount_percent,starts_at,ends_at,created_by,scope) VALUES
 ('50000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Existing 50%',50,
 now()-interval '1 hour',now()+interval '1 hour','20000000-0000-0000-0000-000000000001','selected_items');
INSERT INTO store_promotion_menu_items(promotion_id,restaurant_id,menu_item_id) VALUES
 ('50000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001'),
 ('50000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000002');
UPDATE menu_items SET category_id='80000000-0000-0000-0000-000000000001' WHERE restaurant_id='10000000-0000-0000-0000-000000000001';
CREATE TRIGGER fixture_quantity_discount_write AFTER INSERT OR UPDATE OR DELETE ON order_discounts
FOR EACH ROW EXECUTE FUNCTION fixture_record_write();
CREATE TRIGGER fixture_quantity_line_write AFTER INSERT OR UPDATE OR DELETE ON order_discount_lines
FOR EACH ROW EXECUTE FUNCTION fixture_record_write();
CREATE FUNCTION fixture_quantity_item(p_id integer,p_order integer,p_menu integer,p_qty integer)
RETURNS void LANGUAGE sql AS $$
 INSERT INTO order_items(id,restaurant_id,order_id,menu_item_id,quantity,unit_price)
 VALUES(('60000000-0000-0000-0000-'||lpad(p_id::text,12,'0'))::uuid,'10000000-0000-0000-0000-000000000001',
 ('30000000-0000-0000-0000-'||lpad(p_order::text,12,'0'))::uuid,
 ('40000000-0000-0000-0000-'||lpad(p_menu::text,12,'0'))::uuid,p_qty,100);
$$;
SELECT admin_set_menu_discount_quantity('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',3,NULL);
SELECT admin_set_menu_discount_quantity('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000002',10,NULL);
SELECT fixture_quantity_item(1,1,1,2);
SELECT fixture_assert((SELECT remaining=1 FROM menu_discount_quantities WHERE menu_item_id='40000000-0000-0000-0000-000000000001'),'order immediately reserves two portions without payment');
SELECT fixture_assert(EXISTS(SELECT 1 FROM pos_live_events WHERE domain='menu' AND source_table='menu_discount_quantities' AND event_type='UPDATE'),'quantity changes invalidate the existing customer menu feed');
SELECT fixture_assert((SELECT remaining=10 FROM menu_discount_quantities WHERE menu_item_id='40000000-0000-0000-0000-000000000002'),'other menu balance is independent');
SELECT fixture_assert((SELECT discount_amount=108 FROM order_discounts WHERE order_id='30000000-0000-0000-0000-000000000001' AND status='active'),'existing 50 percent applies to reserved portions including VAT');
SELECT fixture_quantity_item(2,2,1,2);
SELECT fixture_assert((SELECT (promotion_quantity_snapshot->>'quantity')::integer=1 FROM order_items WHERE id='60000000-0000-0000-0000-000000000002'),'one discounted and one normal portion when only one remains');
SELECT fixture_assert((SELECT discount_amount=54 FROM order_discounts WHERE order_id='30000000-0000-0000-0000-000000000002' AND status='active'),'only the reserved quantity receives a discount');
SELECT fixture_quantity_item(3,3,1,1);
SELECT fixture_assert((SELECT (promotion_quantity_snapshot->>'quantity')::integer=0 AND unit_price=100 FROM order_items WHERE id='60000000-0000-0000-0000-000000000003'),'exhausted menu remains orderable at its normal canonical price');
SELECT fixture_assert(NOT EXISTS(SELECT 1 FROM order_discounts WHERE order_id='30000000-0000-0000-0000-000000000003' AND status='active'),'exhaustion does not apply a scheduled discount');
SELECT fixture_assert((SELECT i->>'price'='100' AND i->>'discount_percent'='0' AND i->>'discount_remaining'='0' FROM jsonb_array_elements(qr_get_menu('fixture')->'items')i WHERE i->>'id'='40000000-0000-0000-0000-000000000001'),'catalog shows remaining zero and normal price');
SELECT fixture_assert((qr_get_menu('fixture')->'categories'->0->>'id')='80000000-0000-0000-0000-000000000001','existing discount category remains unchanged');
-- Ending or disabling the campaign must not take an unpaid customer's reservation.
UPDATE store_promotions SET is_active=false WHERE id='50000000-0000-0000-0000-000000000001';
SELECT sync_active_order_promotion('30000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001');
SELECT sync_active_order_promotion('30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001');
SELECT fixture_assert((SELECT discount_amount=108 FROM order_discounts WHERE order_id='30000000-0000-0000-0000-000000000001' AND status='active'),'earlier order retains its discount after later order is refreshed first');
SELECT fixture_assert((SELECT discount_amount=54 FROM order_discounts WHERE order_id='30000000-0000-0000-0000-000000000002' AND status='active'),'promotion end preserves the committed discount');
TRUNCATE fixture_writes;
SELECT sync_active_order_promotion('30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001');
SELECT fixture_assert((SELECT count(*)=0 FROM fixture_writes),'unchanged synchronization does not rewrite allocations');
UPDATE order_items SET status='cancelled' WHERE id='60000000-0000-0000-0000-000000000001';
SELECT fixture_assert((SELECT remaining=2 FROM menu_discount_quantities WHERE menu_item_id='40000000-0000-0000-0000-000000000001'),'cancellation restores exactly the allocated quantity');
UPDATE order_items SET status='cancelled' WHERE id='60000000-0000-0000-0000-000000000001';
SELECT fixture_assert((SELECT remaining=2 FROM menu_discount_quantities WHERE menu_item_id='40000000-0000-0000-0000-000000000001'),'repeated cancellation never restores twice');
UPDATE store_promotions SET is_active=true WHERE id='50000000-0000-0000-0000-000000000001';
UPDATE order_items SET status='ready' WHERE id='60000000-0000-0000-0000-000000000001';
SELECT fixture_assert((SELECT remaining=0 FROM menu_discount_quantities WHERE menu_item_id='40000000-0000-0000-0000-000000000001'),'undoing a cancellation rechecks current availability');
UPDATE order_items SET quantity=1 WHERE id='60000000-0000-0000-0000-000000000001';
SELECT fixture_assert((SELECT remaining=1 FROM menu_discount_quantities WHERE menu_item_id='40000000-0000-0000-0000-000000000001'),'partial cancellation restores only the reduced discounted quantity');
DO $$ BEGIN
 BEGIN
  PERFORM admin_set_menu_discount_quantity('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',100,3);
  RAISE EXCEPTION 'STALE_ADMIN_EDIT_ACCEPTED';
 EXCEPTION WHEN raise_exception THEN
  IF SQLERRM<>'MENU_DISCOUNT_QUANTITY_CHANGED' THEN RAISE; END IF;
 END;
 PERFORM fixture_assert((SELECT remaining=1 FROM menu_discount_quantities WHERE menu_item_id='40000000-0000-0000-0000-000000000001'),'stale admin edit cannot overwrite live order deductions');
 BEGIN
  PERFORM set_config('fixture.reject_line_insert','on',true);
  PERFORM fixture_quantity_item(4,3,1,1);
  RAISE EXCEPTION 'EXPECTED_ALLOCATION_FAILURE';
 EXCEPTION WHEN raise_exception THEN
  IF SQLERRM<>'FIXTURE_ALLOCATION_WRITE_FAILED' THEN RAISE; END IF;
 END;
 PERFORM set_config('fixture.reject_line_insert','off',true);
 PERFORM fixture_assert((SELECT remaining=1 FROM menu_discount_quantities WHERE menu_item_id='40000000-0000-0000-0000-000000000001') AND NOT EXISTS(SELECT 1 FROM order_items WHERE id='60000000-0000-0000-0000-000000000004'),'failed order rolls back its reservation and line');
 BEGIN
  PERFORM validate_menu_option_batch('10000000-0000-0000-0000-000000000001','[{"menu_item_id":"40000000-0000-0000-0000-000000000001","quantity":2,"expected_discount_quantity":2,"expected_discount_percent":50}]','qr');
  RAISE EXCEPTION 'STALE_CUSTOMER_QUOTE_ACCEPTED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'QR_DISCOUNT_QUANTITY_CHANGED' THEN RAISE; END IF; END;
 PERFORM fixture_assert((SELECT remaining=1 FROM menu_discount_quantities WHERE menu_item_id='40000000-0000-0000-0000-000000000001'),'stale QR quote is rejected before order insertion');
END $$;
SELECT validate_menu_option_batch('10000000-0000-0000-0000-000000000001','[{"menu_item_id":"40000000-0000-0000-0000-000000000001","quantity":2,"expected_discount_quantity":1,"expected_discount_percent":50}]','qr');
-- Shared size/meal projections use their registered dish's quota.
UPDATE menu_items SET size_parent_id='40000000-0000-0000-0000-000000000001' WHERE id='40000000-0000-0000-0000-000000000002';
SELECT fixture_quantity_item(5,3,2,1);
SELECT fixture_assert((SELECT remaining=0 FROM menu_discount_quantities WHERE menu_item_id='40000000-0000-0000-0000-000000000001'),'size projection consumes the registered dish quota');
SELECT fixture_assert((SELECT remaining=10 FROM menu_discount_quantities WHERE menu_item_id='40000000-0000-0000-0000-000000000002'),'size projection does not use an independent balance');
SELECT fixture_assert((qr_get_menu('fixture')->>'promotion_discount_percent')::numeric=0,'all exhausted menus stop advertising an active discount');
-- Existing cashier partial transfer carries the reservation without a stock change.
BEGIN;
SELECT set_config('globos.cashier_item_mutation','on',true);
CREATE TEMP TABLE workflow_move_map ON COMMIT DROP AS
 SELECT id source_item_id,'60000000-0000-0000-0000-000000000006'::uuid target_item_id,1 move_count,2 original_count FROM order_items WHERE id='60000000-0000-0000-0000-000000000002';
INSERT INTO order_items(id,restaurant_id,order_id,menu_item_id,quantity,unit_price,promotion_quantity_snapshot)
 SELECT '60000000-0000-0000-0000-000000000006',restaurant_id,'30000000-0000-0000-0000-000000000003',menu_item_id,1,unit_price,promotion_quantity_snapshot
 FROM order_items WHERE id='60000000-0000-0000-0000-000000000002';
UPDATE order_items SET quantity=1 WHERE id='60000000-0000-0000-0000-000000000002';
SELECT fixture_assert((SELECT remaining=0 FROM menu_discount_quantities WHERE menu_item_id='40000000-0000-0000-0000-000000000001'),'table split transfers a reservation without changing remaining stock');
SELECT fixture_assert((SELECT (promotion_quantity_snapshot->>'quantity')::integer=1 FROM order_items WHERE id='60000000-0000-0000-0000-000000000006') AND (SELECT (promotion_quantity_snapshot->>'quantity')::integer=0 FROM order_items WHERE id='60000000-0000-0000-0000-000000000002'),'table split neither duplicates nor loses discounted portions');
COMMIT;
SELECT fixture_assert((SELECT definition=pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure) FROM fixture_payment_anchor),'payment implementation is unchanged');
-- Quantity limits are opt-in; existing unlimited menus still use the old path.
SELECT admin_set_menu_discount_quantity('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',NULL,0);
DO $$ BEGIN
 BEGIN
  PERFORM validate_menu_option_batch('10000000-0000-0000-0000-000000000001','[{"menu_item_id":"40000000-0000-0000-0000-000000000001","quantity":2,"expected_discount_quantity":1,"expected_discount_percent":50}]','qr');
  RAISE EXCEPTION 'LIMIT_REMOVAL_QUOTE_CHANGE_IGNORED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'QR_DISCOUNT_QUANTITY_CHANGED' THEN RAISE; END IF; END;
END $$;
SELECT fixture_quantity_item(7,1,1,1);
SELECT fixture_assert((SELECT promotion_quantity_snapshot IS NULL FROM order_items WHERE id='60000000-0000-0000-0000-000000000007'),'blank quantity restores existing unlimited behavior');
SELECT admin_set_menu_discount_quantity('10000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',1,NULL);
-- Actual RLS/privilege checks, including a store outside the actor's scope.
INSERT INTO menu_discount_quantities(menu_item_id,restaurant_id,remaining) VALUES('40000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000002',7);
GRANT USAGE ON SCHEMA auth TO authenticated;
SET ROLE authenticated;
SELECT fixture_assert((SELECT count(*)=2 FROM menu_discount_quantities),'RLS excludes another store balances');
DO $$ BEGIN
 BEGIN
  UPDATE menu_discount_quantities SET remaining=100 WHERE menu_item_id='40000000-0000-0000-0000-000000000001';
  RAISE EXCEPTION 'DIRECT_QUANTITY_WRITE_ALLOWED';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
 BEGIN
  PERFORM admin_set_menu_discount_quantity('10000000-0000-0000-0000-000000000002','40000000-0000-0000-0000-000000000003',100,7);
  RAISE EXCEPTION 'CROSS_STORE_ADMIN_WRITE_ALLOWED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'ADMIN_MUTATION_FORBIDDEN' THEN RAISE; END IF; END;
END $$;
RESET ROLE;
SET ROLE anon;
SELECT fixture_assert((qr_get_menu('fixture')->>'store_id')='10000000-0000-0000-0000-000000000001','token-authorized customer can read the quota catalog');
DO $$ BEGIN
 BEGIN PERFORM qr_get_menu('invalid'); RAISE EXCEPTION 'INVALID_TOKEN_ALLOWED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'QR_TOKEN_INVALID' THEN RAISE; END IF; END;
 BEGIN PERFORM remaining FROM menu_discount_quantities; RAISE EXCEPTION 'ANON_QUOTA_TABLE_READ_ALLOWED';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
EXPLAIN (ANALYZE,BUFFERS) SELECT remaining FROM menu_discount_quantities
 WHERE menu_item_id='40000000-0000-0000-0000-000000000001' AND restaurant_id='10000000-0000-0000-0000-000000000001';
