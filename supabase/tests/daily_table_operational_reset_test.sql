\set ON_ERROR_STOP on
SET request.jwt.claim.role='authenticated';
SET request.jwt.claim.sub='91000000-0000-4000-8000-000000000003';
-- Fixtures use actual legacy QR/order/cancellation functions. Create states
-- with the rollout disabled, then enable the same policy used in production.
CREATE FUNCTION test_seed_reset_order(n integer,days_old integer,order_status text,paid numeric DEFAULT 0,table_n integer DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE oid uuid:=test_uuid(2000+n); tid uuid:=test_uuid(100+COALESCE(table_n,n+1));
BEGIN
 INSERT INTO orders(id,restaurant_id,table_id,status,created_at)
 VALUES(oid,test_uuid(1),tid,order_status,
  ((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')-days_old*interval '1 day');
 INSERT INTO order_items(id,order_id,restaurant_id,menu_item_id,status)
 VALUES(test_uuid(3000+n),oid,test_uuid(1),test_uuid(10),'ready');
 IF paid>0 THEN INSERT INTO payments(order_id,restaurant_id,amount) VALUES(oid,test_uuid(1),paid); END IF;
 UPDATE tables SET status='occupied' WHERE id=tid;
 RETURN oid;
END $$;
INSERT INTO table_operational_reset_policies(restaurant_id,is_enabled) VALUES(test_uuid(1),false);
SELECT test_seed_reset_order(1,1,'pending');
SELECT test_seed_reset_order(2,2,'confirmed');
SELECT test_seed_reset_order(3,10,'serving');
SELECT test_seed_reset_order(4,1,'serving',40);
SELECT test_seed_reset_order(5,0,'serving',0,5); -- today's order shares yesterday's paid table
SELECT test_seed_reset_order(6,1,'completed',100);
SELECT test_seed_reset_order(7,1,'cancelled');
SELECT test_seed_reset_order(8,1,'serving');
UPDATE orders SET sales_channel='delivery' WHERE id=test_uuid(2008);
SELECT test_seed_reset_order(9,0,'pending');
SELECT test_seed_reset_order(10,1,'serving');
UPDATE orders SET restaurant_id=test_uuid(2) WHERE id=test_uuid(2010);
SELECT test_seed_reset_order(11,3,'pending');
DELETE FROM order_items WHERE order_id=test_uuid(2011); -- empty forgotten order
UPDATE tables SET status='reserved' WHERE id=test_uuid(119);
UPDATE tables SET status='occupied' WHERE id=test_uuid(120);
INSERT INTO emergency_fulfillment_items(order_id,order_item_id,kitchen_started_quantity,kitchen_done_quantity,
 tray_received_quantity,tray_dispatched_quantity,floor_served_quantity)
VALUES(test_uuid(1001),(SELECT id FROM order_items WHERE order_id=test_uuid(1001) LIMIT 1),1,1,1,1,0);
INSERT INTO emergency_combo_component_items(order_id,order_item_id) VALUES(test_uuid(2004),test_uuid(3004));
INSERT INTO emergency_floor_direct_items(order_id,order_item_id,floor_served_quantity) VALUES(test_uuid(2004),test_uuid(3004),1);
INSERT INTO emergency_floor_ready_lots(order_id,ready_quantity,served_quantity) VALUES(test_uuid(2004),3,1);
INSERT INTO leftover_packaging_requests(order_id) VALUES(test_uuid(2004));
INSERT INTO print_jobs(order_id,status) VALUES(test_uuid(2004),'pending'),(test_uuid(2004),'done');
INSERT INTO einvoice_jobs VALUES(test_uuid(5000),test_uuid(2006),'pending');
INSERT INTO customer_payment_displays(store_id,order_id,status,payload) VALUES(test_uuid(1),test_uuid(2004),'showing','{"phase":"payment"}');
UPDATE table_operational_reset_policies SET is_enabled=true;

SELECT ensure_store_operational_day(test_uuid(1));
SELECT test_assert((SELECT status='available' FROM tables WHERE id=test_uuid(101)),'incident table released');
SELECT test_assert((SELECT status='cancelled' AND operational_closed_at IS NOT NULL FROM orders WHERE id=test_uuid(1001)),'incident order cancelled');
SELECT test_assert((SELECT count(*)=2 AND bool_and(status='cancelled') FROM order_items WHERE order_id=test_uuid(1001)),'including today-added item closed with its old parent');
SELECT test_assert((SELECT count(*)=5 FROM order_operational_closures WHERE closure_kind='unpaid_cancelled'),'all overdue statuses and missed days closed');
SELECT test_assert((SELECT count(*)=1 AND min(paid_total)=40 FROM order_operational_closures WHERE closure_kind='financial_review'),'partial payment review recorded');
SELECT test_assert((SELECT status='serving' AND operational_closed_at IS NOT NULL AND table_id=test_uuid(105) FROM orders WHERE id=test_uuid(2004)),'paid parent facts retained');
SELECT test_assert((SELECT status='ready' FROM order_items WHERE id=test_uuid(3004)),'paid line not financially cancelled');
SELECT test_assert((SELECT status='occupied' FROM tables WHERE id=test_uuid(105)),'today order prevents old table release');
SELECT test_assert((SELECT count(*)=1 AND min(amount)=40 FROM payments WHERE order_id=test_uuid(2004)),'partial receipt unchanged');
SELECT test_assert((SELECT current_stock=98 FROM inventory_items),'consumed inventory unchanged');
SELECT test_assert((SELECT count(*)=1 AND sum(quantity)=-2 FROM inventory_transactions),'inventory ledger unchanged');
SELECT test_assert((SELECT count(*)=1 AND min(status)='pending' FROM einvoice_jobs),'invoice job unchanged');
SELECT test_assert((SELECT status='idle' AND order_id IS NULL FROM customer_payment_displays),'expired payment collection display cleared');
SELECT test_assert(get_store_sales_cancellation_total(test_uuid(1),now()-interval '1 hour',now()+interval '1 hour')=450,'report includes system cancellation amounts exactly once');
SELECT test_assert((SELECT status='serving' AND operational_closed_at IS NULL FROM orders WHERE id=test_uuid(2008)),'delivery order untouched');
SELECT test_assert((SELECT operational_closed_at IS NULL FROM orders WHERE id=test_uuid(2010)),'other store untouched');
SELECT test_assert((SELECT status='reserved' FROM tables WHERE id=test_uuid(119)),'reservations untouched');
SELECT test_assert((SELECT status='available' FROM tables WHERE id=test_uuid(120)),'orphan occupancy repaired');
SELECT test_assert((SELECT bool_and(is_cancelled) FROM emergency_fulfillment_items),'kitchen fulfillment closed');
SELECT test_assert((SELECT bool_and(is_cancelled) FROM emergency_combo_component_items),'combo fulfillment closed');
SELECT test_assert((SELECT is_cancelled AND floor_served_quantity=1 FROM emergency_floor_direct_items),'served quantities retained');
SELECT test_assert((SELECT ready_quantity=3 AND served_quantity=1 AND voided_quantity=2 FROM emergency_floor_ready_lots),'pending ready lots voided only');
SELECT test_assert((SELECT status='cancelled' FROM leftover_packaging_requests),'leftovers no longer pending');
SELECT test_assert((SELECT count(*)=1 FROM print_jobs WHERE order_id=test_uuid(2004) AND status='done'),'printed receipt retained');
SELECT test_assert((SELECT count(*)=1 FROM print_jobs WHERE order_id=test_uuid(2004) AND status='cancelled'),'pending print cancelled');
SELECT ensure_store_operational_day(test_uuid(1));
SELECT test_assert((SELECT count(*)=6 FROM order_operational_closures),'repeat reset is idempotent');
SELECT test_assert(NOT (qr_get_active_order('incident-qr')->>'active')::boolean,'QR sees empty table after closure');

DO $$ BEGIN
 BEGIN UPDATE orders SET status='serving',operational_closed_at=NULL,operational_close_reason=NULL WHERE id=test_uuid(1001);
 RAISE EXCEPTION 'REOPEN_ACCEPTED'; EXCEPTION WHEN OTHERS THEN PERFORM test_assert(SQLERRM='ORDER_OPERATIONS_CLOSED','closed parent cannot reopen'); END;
 BEGIN UPDATE order_items SET status='ready' WHERE order_id=test_uuid(1001);
 RAISE EXCEPTION 'ITEM_REOPEN_ACCEPTED'; EXCEPTION WHEN OTHERS THEN PERFORM test_assert(SQLERRM='ORDER_BUSINESS_DAY_EXPIRED','closed item cannot reopen'); END;
 BEGIN UPDATE emergency_floor_direct_items SET is_cancelled=false;
 RAISE EXCEPTION 'FULFILLMENT_REOPEN_ACCEPTED'; EXCEPTION WHEN OTHERS THEN PERFORM test_assert(SQLERRM='ORDER_BUSINESS_DAY_EXPIRED','fulfillment cannot reopen'); END;
 BEGIN INSERT INTO emergency_floor_ready_lots(order_id) VALUES(test_uuid(2004));
 RAISE EXCEPTION 'READY_LOT_REOPEN_ACCEPTED'; EXCEPTION WHEN OTHERS THEN PERFORM test_assert(SQLERRM='ORDER_BUSINESS_DAY_EXPIRED','late ready event cannot reopen'); END;
 BEGIN UPDATE leftover_packaging_requests SET status='awaiting_floor_pickup' WHERE order_id=test_uuid(2004);
 RAISE EXCEPTION 'LEFTOVER_REOPEN_ACCEPTED'; EXCEPTION WHEN OTHERS THEN PERFORM test_assert(SQLERRM='ORDER_BUSINESS_DAY_EXPIRED','leftover request cannot reopen'); END;
 BEGIN INSERT INTO print_jobs(order_id,copy_type) VALUES(test_uuid(2004),'kitchen');
 RAISE EXCEPTION 'KITCHEN_PRINT_REOPEN_ACCEPTED'; EXCEPTION WHEN OTHERS THEN PERFORM test_assert(SQLERRM='ORDER_BUSINESS_DAY_EXPIRED','late kitchen print cannot reopen'); END;
 BEGIN INSERT INTO payments(order_id,restaurant_id,amount) VALUES(test_uuid(2004),test_uuid(1),60);
 RAISE EXCEPTION 'LATE_PAYMENT_ACCEPTED'; EXCEPTION WHEN OTHERS THEN PERFORM test_assert(SQLERRM='ORDER_OPERATIONS_CLOSED','late payment requires review rather than new table use'); END;
 BEGIN UPDATE order_operational_closures SET paid_total=0;
 RAISE EXCEPTION 'LEDGER_UPDATE_ACCEPTED'; EXCEPTION WHEN OTHERS THEN PERFORM test_assert(SQLERRM='OPERATIONAL_CLOSURE_IMMUTABLE','ledger immutable'); END;
 BEGIN PERFORM restore_cancelled_order(test_uuid(2007),test_uuid(1));
 -- Legacy parent cancellation has no ledger in this fixture. Exercise the
 -- protected state transition itself separately below.
 EXCEPTION WHEN OTHERS THEN NULL; END;
 BEGIN UPDATE orders SET status='pending' WHERE id=test_uuid(2007);
 RAISE EXCEPTION 'OLD_CANCEL_RESTORE_ACCEPTED'; EXCEPTION WHEN OTHERS THEN PERFORM test_assert(SQLERRM='ORDER_BUSINESS_DAY_EXPIRED','preexisting cancellation cannot restore into next day'); END;
 BEGIN PERFORM create_order_for_business_day(test_uuid(1),test_uuid(101),'[]','expired-offline',
  (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date-1);
 RAISE EXCEPTION 'OLD_OFFLINE_ACCEPTED'; EXCEPTION WHEN OTHERS THEN PERFORM test_assert(SQLERRM='ORDER_BUSINESS_DAY_EXPIRED','server rejects expired offline creation'); END;
 BEGIN PERFORM qr_place_order('incident-qr','[{"menu_item_id":"91000000-0000-4000-8000-000000000011","quantity":1}]',
  test_uuid(1600),true,test_uuid(1001));
 RAISE EXCEPTION 'STALE_QR_ACCEPTED'; EXCEPTION WHEN OTHERS THEN PERFORM test_assert(SQLERRM='QR_ORDER_CONTEXT_CHANGED','stale QR context cannot attach to new table'); END;
END $$;
INSERT INTO print_jobs(order_id,copy_type) VALUES(test_uuid(2004),'receipt');
SELECT test_assert((SELECT count(*)=1 FROM print_jobs WHERE order_id=test_uuid(2004) AND copy_type='receipt'),'historical payment receipt can still be printed');
-- Real QR core creates a fresh order on the released table and cashier search
-- finds it in today's scope. Throttle from the reproduction batch is expired.
UPDATE qr_order_batches SET created_at=now()-interval '1 minute';
SELECT test_assert(qr_place_order('incident-qr','[{"menu_item_id":"91000000-0000-4000-8000-000000000011","quantity":1}]',
 test_uuid(1601),true,NULL)->>'order_id'<>test_uuid(1001)::text,'new QR order is not yesterday parent');
SELECT test_assert(search_active_order_for_cashier(test_uuid(1),'1') IS NOT NULL,'cashier can find new order');
UPDATE tables SET status='available' WHERE id=test_uuid(101);
SELECT test_assert((SELECT status='occupied' FROM tables WHERE id=test_uuid(101)),'legacy release cannot clear today order');

DO $$ BEGIN
 BEGIN PERFORM cancel_current_table_order(test_uuid(1),test_uuid(110),'');
 RAISE EXCEPTION 'EMPTY_REASON_ACCEPTED'; EXCEPTION WHEN OTHERS THEN PERFORM test_assert(SQLERRM='ORDER_CANCEL_REASON_REQUIRED','cashier cancellation needs reason'); END;
 BEGIN PERFORM cancel_current_table_order(test_uuid(1),test_uuid(105),'No customer');
 -- This table has today's unpaid order, so cancelling it is allowed and must
 -- keep the previous paid receipt attached to the old closed order.
 EXCEPTION WHEN OTHERS THEN RAISE; END;
END $$;
SELECT test_assert((SELECT status='available' FROM tables WHERE id=test_uuid(105)),'closed partial order does not block manual release');
SELECT test_assert((SELECT amount=40 FROM payments WHERE order_id=test_uuid(2004)),'manual release retains old receipt');
SET request.jwt.claim.sub='91000000-0000-4000-8000-000000000004';
DO $$ BEGIN
 BEGIN PERFORM cancel_current_table_order(test_uuid(1),test_uuid(110),'No customer');
 RAISE EXCEPTION 'WAITER_CLEAR_ACCEPTED'; EXCEPTION WHEN OTHERS THEN PERFORM test_assert(SQLERRM='ORDER_MUTATION_FORBIDDEN','waiter cannot use cashier clear'); END;
END $$;
SET ROLE authenticated;
SELECT test_assert((SELECT count(*)=0 FROM order_operational_closures),'waiter cannot read financial closure snapshots');
RESET ROLE;
SET request.jwt.claim.sub='91000000-0000-4000-8000-000000000005';
DO $$ BEGIN
 BEGIN PERFORM ensure_store_operational_day(test_uuid(1));
 RAISE EXCEPTION 'CROSS_STORE_RESET_ACCEPTED'; EXCEPTION WHEN OTHERS THEN PERFORM test_assert(SQLERRM='ORDER_MUTATION_FORBIDDEN','reset respects store access'); END;
END $$;
SET ROLE authenticated;
SELECT test_assert((SELECT count(*)=0 FROM order_operational_closures),'other store cannot read closures');
RESET ROLE;
SET request.jwt.claim.sub='91000000-0000-4000-8000-000000000003';
SET ROLE authenticated;
SELECT test_assert((SELECT count(*)=6 FROM order_operational_closures),'cashier sees own store closures');
RESET ROLE;
SELECT 'DAILY_TABLE_OPERATIONAL_RESET_BEHAVIOR_PASS';
