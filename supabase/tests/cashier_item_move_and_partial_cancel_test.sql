DO $test$
DECLARE store uuid:=gen_random_uuid();menu uuid:=gen_random_uuid();t1 uuid:=gen_random_uuid();t2 uuid:=gen_random_uuid();t3 uuid:=gen_random_uuid();o1 uuid; o2 uuid;item uuid;other_item uuid;session uuid;queue uuid;progress uuid;op uuid;value jsonb;target_item uuid;before jsonb; source_quantity integer;
BEGIN
 INSERT INTO brands DEFAULT VALUES;
 INSERT INTO restaurants(id,brand_id) SELECT store,id FROM brands LIMIT 1;
 INSERT INTO tables(id,restaurant_id,table_number,floor_label,status) VALUES(t1,store,'1103','1F','occupied'),(t2,store,'1104','2F','occupied'),(t3,store,'1105','2F','available');
 INSERT INTO menu_items(id,restaurant_id,vat_category,name) VALUES(menu,store,'food','Test');
 INSERT INTO orders(restaurant_id,table_id,status,fulfillment_mode_snapshot) VALUES(store,t1,'serving','paperless') RETURNING id INTO o1;
 INSERT INTO orders(restaurant_id,table_id,status,fulfillment_mode_snapshot) VALUES(store,t2,'serving','paperless') RETURNING id INTO o2;
 -- Initial fixture ordering is independent of the new RPC and its no-reprint guard.
 PERFORM set_config('globos.cashier_item_mutation','on',true);
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,label,unit_price,quantity,status,paying_amount_inc_tax,fulfillment_mode_snapshot,combo_components)
 VALUES(store,o1,menu,'Sausage',10000,3,'served',32400,'paperless','[]') RETURNING id INTO item;
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,label,unit_price,quantity,status,paying_amount_inc_tax,fulfillment_mode_snapshot,combo_components)
 VALUES(store,o2,menu,'Paid menu',20000,1,'served',21600,'paperless','[]') RETURNING id INTO other_item;
 PERFORM set_config('globos.cashier_item_mutation','off',true);
 INSERT INTO emergency_fulfillment_sessions(restaurant_id,reason) VALUES(store,'Fixture') RETURNING id INTO session;
 INSERT INTO emergency_order_queue(session_id,restaurant_id,order_id,queue_no,table_number,floor_label) VALUES(session,store,o1,1,'1103','1F') RETURNING id INTO queue;
 INSERT INTO emergency_fulfillment_items(session_id,restaurant_id,queue_id,order_id,order_item_id,source_quantity,ordered_quantity,kitchen_started_quantity,kitchen_done_quantity,tray_received_quantity,tray_dispatched_quantity,floor_served_quantity)
 VALUES(session,store,queue,o1,item,3,3,3,3,3,3,3) RETURNING id INTO progress;
 op:=gen_random_uuid();
 value:=public.cashier_cancel_item_quantity(store,item,3,2,op,'customer_request');
 IF (SELECT quantity FROM order_items WHERE id=item)<>2 OR (SELECT floor_served_quantity FROM emergency_fulfillment_items WHERE id=progress)<>3 OR (SELECT needs_review FROM emergency_fulfillment_items WHERE id=progress) THEN RAISE EXCEPTION 'PARTIAL_CANCEL_LOST_SERVED_HISTORY'; END IF;
 IF (SELECT cancelled_amount FROM order_cancellation_ledger WHERE order_item_id=item)<>10800 THEN RAISE EXCEPTION 'PARTIAL_CANCEL_AMOUNT_WRONG'; END IF;
 PERFORM public.cashier_cancel_item_quantity(store,item,3,2,op,'customer_request');
 IF (SELECT count(*) FROM order_cancellation_ledger WHERE order_item_id=item)<>1 THEN RAISE EXCEPTION 'PARTIAL_RETRY_DUPLICATED'; END IF;
 PERFORM public.cashier_restore_item_quantity(store,op);
 IF (SELECT quantity FROM order_items WHERE id=item)<>3 OR (SELECT floor_served_quantity FROM emergency_fulfillment_items WHERE id=progress)<>3 THEN RAISE EXCEPTION 'PARTIAL_UNDO_BROKEN'; END IF;
 PERFORM public.cashier_cancel_item_quantity(store,item,3,2,gen_random_uuid(),'customer_request');
 PERFORM public.cashier_cancel_item_quantity(store,item,2,1,gen_random_uuid(),'customer_request');
 IF (SELECT count(*) FROM order_cancellation_ledger WHERE order_item_id=item)<>3 OR (SELECT floor_served_quantity FROM emergency_fulfillment_items WHERE id=progress)<>3 THEN RAISE EXCEPTION 'REPEATED_PARTIAL_CANCEL_BROKEN'; END IF;
 op:=gen_random_uuid();value:=public.cashier_move_order_items(store,o1,t2,jsonb_build_array(jsonb_build_object('item_id',item,'quantity',1,'expected_quantity',1)),op);
 IF value->>'target_order_id'<>o2::text OR (SELECT order_id FROM order_items WHERE id=item)<>o2 OR NOT EXISTS(SELECT 1 FROM emergency_fulfillment_items f JOIN emergency_order_queue q ON q.id=f.queue_id WHERE f.id=progress AND f.order_id=o2 AND q.floor_label='2F' AND f.floor_served_quantity=3) THEN RAISE EXCEPTION 'WHOLE_ITEM_MOVE_LOST_PROGRESS'; END IF;
 PERFORM public.cashier_move_order_items(store,o1,t2,jsonb_build_array(jsonb_build_object('item_id',item,'quantity',1,'expected_quantity',1)),op);
 IF (SELECT status FROM tables WHERE id=t1)<>'available' THEN RAISE EXCEPTION 'EMPTY_SOURCE_TABLE_OCCUPIED'; END IF;
 -- Split a separate untouched line, including a prepared but unserved unit.
 PERFORM set_config('globos.cashier_item_mutation','on',true);
 UPDATE order_items SET quantity=3,paying_amount_inc_tax=64800,vat_amount=4800,total_amount_ex_tax=60000 WHERE id=other_item;
 PERFORM set_config('globos.cashier_item_mutation','off',true);
 SELECT id INTO queue FROM emergency_order_queue WHERE session_id=session AND order_id=o2;
 INSERT INTO emergency_fulfillment_items(session_id,restaurant_id,queue_id,order_id,order_item_id,source_quantity,ordered_quantity,kitchen_started_quantity,kitchen_done_quantity,tray_received_quantity,tray_dispatched_quantity,floor_served_quantity)
 VALUES(session,store,queue,o2,other_item,3,3,2,1,1,1,0);
 value:=public.cashier_move_order_items(store,o2,t3,jsonb_build_array(jsonb_build_object('item_id',other_item,'quantity',1,'expected_quantity',3)),gen_random_uuid());
 target_item:=(value->'moved'->0->>'target_item_id')::uuid;
 IF target_item=other_item OR (SELECT quantity FROM order_items WHERE id=other_item)<>2 OR (SELECT quantity FROM order_items WHERE id=target_item)<>1 OR (SELECT sum(kitchen_done_quantity) FROM emergency_fulfillment_items WHERE order_item_id IN (target_item,other_item))<>1 THEN RAISE EXCEPTION 'PARTIAL_MOVE_REORDERED_FOOD'; END IF;
 BEGIN PERFORM public.cashier_cancel_item_quantity(store,target_item,2,1,gen_random_uuid(),'stale');RAISE EXCEPTION 'STALE_QUANTITY_ACCEPTED'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'CASHIER_ITEM_CHANGED' THEN RAISE; END IF; END;
 INSERT INTO payments(order_id,restaurant_id,amount,amount_portion) VALUES(o2,store,1,1);
 BEGIN PERFORM public.cashier_cancel_item_quantity(store,other_item,2,1,gen_random_uuid(),'paid');RAISE EXCEPTION 'PAID_QUANTITY_EDITED'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'ORDER_HAS_PAYMENTS_USE_ADJUSTMENT' THEN RAISE; END IF; END;
 UPDATE users SET role='waiter';
 BEGIN PERFORM public.cashier_move_order_items(store,o2,t1,jsonb_build_array(jsonb_build_object('item_id',other_item,'quantity',1,'expected_quantity',2)),gen_random_uuid());RAISE EXCEPTION 'WAITER_MOVE_ALLOWED'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'ORDER_MUTATION_FORBIDDEN' THEN RAISE; END IF; END;
 UPDATE users SET role='cashier';
 IF EXISTS(SELECT 1 FROM emergency_fulfillment_events WHERE restaurant_id=store AND stage='order_received') THEN RAISE EXCEPTION 'ITEM_MUTATION_ENQUEUED_NEW_FOOD'; END IF;
 DELETE FROM payments WHERE order_id=o2;
 -- Stock reflects the original three served units, while the bill keeps one.
 UPDATE users SET role='cashier';
 PERFORM set_config('globos.cashier_item_mutation','on',true);
 UPDATE order_items SET status='served',paying_amount_inc_tax=10800,vat_rate=8,vat_amount=800,total_amount_ex_tax=10000 WHERE id=item;
 PERFORM set_config('globos.cashier_item_mutation','off',true);
 DECLARE ingredient uuid:=gen_random_uuid(); BEGIN
  INSERT INTO inventory_items(id,restaurant_id,current_stock) VALUES(ingredient,store,1000);
  INSERT INTO menu_recipes(menu_item_id,restaurant_id,ingredient_id,quantity_g) VALUES(menu,store,ingredient,10);
  PERFORM public.process_payment(o2,store,54000,'CASH');
  IF (SELECT current_stock FROM inventory_items WHERE id=ingredient)<>950 THEN RAISE EXCEPTION 'CANCELLED_SERVED_STOCK_RESTORED'; END IF;
 END;
END; $test$;
SELECT 'CASHIER_ITEM_MOVE_AND_PARTIAL_CANCEL=PASS';

DO $combo_and_lots$
DECLARE store uuid; menu uuid; t uuid:=gen_random_uuid(); o uuid; i uuid; session uuid; queue uuid; progress uuid; op uuid; comp uuid; v jsonb;
BEGIN
 SELECT restaurant_id,menu_item_id INTO store,menu FROM public.order_items LIMIT 1;
 SELECT id INTO session FROM public.emergency_fulfillment_sessions WHERE restaurant_id=store;
 INSERT INTO tables(id,restaurant_id,table_number,floor_label,status) VALUES(t,store,'1110','1F','occupied');
 INSERT INTO orders(restaurant_id,table_id,status,fulfillment_mode_snapshot) VALUES(store,t,'confirmed','paperless') RETURNING id INTO o;
 PERFORM set_config('globos.cashier_item_mutation','on',true);
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,label,unit_price,quantity,status,paying_amount_inc_tax,fulfillment_mode_snapshot,combo_components,is_service_item) VALUES(store,o,menu,'Combo free',10000,3,'pending',32400,'paperless',jsonb_build_array(jsonb_build_object('menu_item_id',menu,'quantity',2,'is_total_quantity',false)),true) RETURNING id INTO i;
 PERFORM set_config('globos.cashier_item_mutation','off',true);
 INSERT INTO emergency_order_queue(session_id,restaurant_id,order_id,queue_no,table_number,floor_label) SELECT session,store,o,max(queue_no)+1,'1110','1F' FROM emergency_order_queue WHERE session_id=session RETURNING id INTO queue;
 INSERT INTO emergency_combo_component_items(session_id,restaurant_id,queue_id,order_id,order_item_id,line_key,component_menu_item_id,name_ko,name_vi,name_en,source_quantity,ordered_quantity,kitchen_started_quantity,kitchen_done_quantity,tray_received_quantity,tray_dispatched_quantity,floor_served_quantity) VALUES(session,store,queue,o,i,'combo:'||menu,menu,'Combo','Combo','Combo',6,6,6,6,6,6,2) RETURNING id INTO comp;
 INSERT INTO emergency_floor_ready_lots(restaurant_id,session_id,queue_id,order_id,order_item_id,source_kind,source_id,ready_action_id,ready_sequence,ready_quantity,served_quantity) VALUES(store,session,queue,o,i,'combo_component',comp,gen_random_uuid(),1,6,2);
 op:=gen_random_uuid(); PERFORM public.cashier_cancel_item_quantity(store,i,3,2,op,'customer_request');
 IF (SELECT source_quantity FROM emergency_combo_component_items WHERE id=comp)<>4 OR (SELECT floor_served_quantity FROM emergency_combo_component_items WHERE id=comp)<>2 OR (SELECT voided_quantity FROM emergency_floor_ready_lots WHERE source_id=comp)<>2 OR (SELECT cancelled_amount FROM order_cancellation_ledger WHERE order_item_id=i)<>0 THEN RAISE EXCEPTION 'COMBO_FREE_PARTIAL_CANCEL_BAD'; END IF;
 -- Future status updates must not revive the cancelled operational units.
 UPDATE order_items SET status='preparing' WHERE id=i;
 IF (SELECT ordered_quantity-excused_quantity FROM emergency_combo_component_items WHERE id=comp)<>4 THEN RAISE EXCEPTION 'PARTIAL_CANCEL_REVIVED_BY_KDS_SYNC'; END IF;
 UPDATE emergency_combo_component_items SET floor_served_quantity=3 WHERE id=comp;
 BEGIN PERFORM public.cashier_restore_item_quantity(store,op);RAISE EXCEPTION 'UNDO_OVERWROTE_NEW_PROGRESS'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'CASHIER_ITEM_CHANGED' THEN RAISE; END IF; END;
 PERFORM public.cashier_cancel_item_quantity(store,i,2,1,gen_random_uuid(),'customer_request');
 v:=public.cashier_resize_combo(jsonb_build_array(jsonb_build_object('menu_item_id',menu,'quantity',1,'is_total_quantity',true),jsonb_build_object('menu_item_id',gen_random_uuid(),'quantity',1,'is_total_quantity',true)),2,1);
 IF jsonb_array_length(v)<>1 OR (v->0->>'quantity')::integer<>1 THEN RAISE EXCEPTION 'MIXED_DRINK_CHOICE_CANCEL_INVALID'; END IF;
END; $combo_and_lots$;
SELECT 'CASHIER_COMBO_READY_LOTS_AND_STOCK=PASS';

DO $full_after_partial$
DECLARE store uuid; menu uuid; o uuid; i uuid; amount numeric;
BEGIN
 SELECT restaurant_id,menu_item_id INTO store,menu FROM public.order_items LIMIT 1;
 INSERT INTO orders(restaurant_id,status) VALUES(store,'confirmed') RETURNING id INTO o;
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,label,unit_price,quantity,status,paying_amount_inc_tax,vat_amount,total_amount_ex_tax)
 VALUES(store,o,menu,'Three drinks',10000,3,'pending',32400,2400,30000) RETURNING id INTO i;
 PERFORM public.cashier_cancel_item_quantity(store,i,3,2,gen_random_uuid(),'customer_request');
 PERFORM public.cashier_cancel_item_quantity(store,i,2,1,gen_random_uuid(),'customer_request');
 PERFORM public.cancel_order_item(i,store);
 SELECT sum(cancelled_amount) INTO amount FROM public.order_cancellation_ledger WHERE order_item_id=i;
 IF amount<>32400 OR (SELECT sum(quantity) FROM public.order_cancellation_ledger WHERE order_item_id=i)<>3 THEN RAISE EXCEPTION 'REMAINING_FULL_CANCELLATION_DOUBLE_COUNTED'; END IF;
 PERFORM public.restore_cancelled_order_item(i,store);
 IF (SELECT quantity FROM public.order_items WHERE id=i)<>1 OR (SELECT billing_cancelled_quantity FROM public.order_items WHERE id=i)<>2 THEN RAISE EXCEPTION 'FULL_UNDO_RESTORED_PARTIAL_CANCELLATIONS'; END IF;
 IF EXISTS(SELECT 1 FROM public.cashier_item_operations op JOIN public.order_cancellation_reversals rev ON rev.cancellation_ledger_id=op.ledger_id WHERE op.order_id=o) THEN RAISE EXCEPTION 'FULL_UNDO_REVERSED_PARTIAL_LEDGER'; END IF;
END; $full_after_partial$;
SELECT 'CASHIER_REPEATED_PARTIAL_AND_FULL_CANCEL=PASS';

DO $prepared_repeated$
DECLARE store uuid; menu uuid; session uuid; o uuid; i uuid; queue uuid; progress uuid; ingredient uuid:=gen_random_uuid();
BEGIN
 SELECT restaurant_id,menu_item_id INTO store,menu FROM public.order_items LIMIT 1;
 SELECT id INTO session FROM public.emergency_fulfillment_sessions WHERE restaurant_id=store;
 INSERT INTO orders(restaurant_id,status,fulfillment_mode_snapshot) VALUES(store,'confirmed','paperless') RETURNING id INTO o;
 PERFORM set_config('globos.cashier_item_mutation','on',true);
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,label,unit_price,quantity,status,paying_amount_inc_tax,fulfillment_mode_snapshot) VALUES(store,o,menu,'Prepared unserved',10000,3,'ready',32400,'paperless') RETURNING id INTO i;
 PERFORM set_config('globos.cashier_item_mutation','off',true);
 INSERT INTO emergency_order_queue(session_id,restaurant_id,order_id,queue_no,table_number,floor_label) SELECT session,store,o,max(queue_no)+1,'1111','1F' FROM emergency_order_queue WHERE session_id=session RETURNING id INTO queue;
 INSERT INTO emergency_fulfillment_items(session_id,restaurant_id,queue_id,order_id,order_item_id,source_quantity,ordered_quantity,kitchen_started_quantity,kitchen_done_quantity) VALUES(session,store,queue,o,i,3,3,3,3) RETURNING id INTO progress;
 PERFORM public.cashier_cancel_item_quantity(store,i,3,2,gen_random_uuid(),'customer_request');
 PERFORM public.cashier_cancel_item_quantity(store,i,2,1,gen_random_uuid(),'customer_request');
 IF (SELECT quantity+cancelled_consumed_quantity FROM order_items WHERE id=i)<>3 OR (SELECT kitchen_done_quantity FROM emergency_fulfillment_items WHERE id=progress)<>1 THEN RAISE EXCEPTION 'REPEATED_PREPARED_CANCEL_LOST_CONSUMPTION'; END IF;
 -- Cancel the residual line, undo, then cancel again. Prepared consumption
 -- survives the whole cancellation without inflating its restored quantity.
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,label,unit_price,quantity,status,paying_amount_inc_tax,vat_rate,vat_amount,total_amount_ex_tax,fulfillment_mode_snapshot)
 VALUES(store,o,menu,'Remaining paid menu',10000,1,'served',10800,8,800,10000,'paperless');
 PERFORM public.cancel_order_item(i,store);
 IF (SELECT cancelled_consumed_quantity FROM order_items WHERE id=i)<>3 THEN RAISE EXCEPTION 'FULL_CANCEL_LOST_PREPARED_CONSUMPTION'; END IF;
 PERFORM public.restore_cancelled_order_item(i,store);
 IF (SELECT quantity+cancelled_consumed_quantity FROM order_items WHERE id=i)<>3 THEN RAISE EXCEPTION 'FULL_UNDO_DOUBLE_COUNTED_CONSUMPTION'; END IF;
 PERFORM public.cancel_order_item(i,store);
 INSERT INTO inventory_items(id,restaurant_id,current_stock) VALUES(ingredient,store,1000);
 INSERT INTO menu_recipes(menu_item_id,restaurant_id,ingredient_id,quantity_g) VALUES(menu,store,ingredient,10);
 PERFORM public.process_payment(o,store,10800,'CASH');
 IF (SELECT current_stock FROM inventory_items WHERE id=ingredient)<>960 THEN RAISE EXCEPTION 'WHOLE_CANCEL_EXCLUDED_CONSUMED_STOCK'; END IF;
END; $prepared_repeated$;
SELECT 'CASHIER_REPEATED_PREPARED_CONSUMPTION=PASS';
