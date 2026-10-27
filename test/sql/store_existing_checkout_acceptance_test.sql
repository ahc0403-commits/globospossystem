-- Current production schema; synthetic store-scoped cashiers and QR orders.
-- Run only via scripts/test_store_existing_checkout_acceptance.sh, which
-- creates an internal-only disposable database with no external workers.
BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
UPDATE brands SET service_charge_enabled=false;
UPDATE restaurants SET vat_pricing_mode='exclusive';
INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at)
SELECT ('92000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 'cashier-lab-'||n||'@internal.invalid','00000000-0000-0000-0000-000000000000','authenticated','authenticated',now() FROM generate_series(101,102) n;
INSERT INTO public.users(id,auth_id,restaurant_id,role,full_name,is_active)
SELECT ('93000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 ('92000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 CASE n WHEN 101 THEN '273b057e-3b69-46e3-93c1-6194c2802849'::uuid ELSE '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid END,
 'cashier','Isolated store cashier',true FROM generate_series(101,102) n;
INSERT INTO user_store_access(user_id,store_id,is_primary,is_active,source_type)
SELECT id,restaurant_id,true,true,'direct' FROM users WHERE full_name='Isolated store cashier';
DO $$
DECLARE
 shop uuid; menu uuid; tab uuid; ingredient uuid; qr text; request uuid; client_request uuid;
 result jsonb; retry jsonb; oid uuid; item uuid; queue uuid; allocation jsonb; actor text;
 direct boolean; stored_floor text; floor_actor text; wrong_actor text; own_cashier text; foreign_cashier text;
BEGIN
 FOR shop,direct,stored_floor,floor_actor,wrong_actor IN VALUES
 ('273b057e-3b69-46e3-93c1-6194c2802849'::uuid,true,'2F','92000000-0000-4000-8000-000000000003','92000000-0000-4000-8000-000000000004'),
 ('273b057e-3b69-46e3-93c1-6194c2802849'::uuid,true,'3F','92000000-0000-4000-8000-000000000004','92000000-0000-4000-8000-000000000003'),
 ('8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,false,'1F','92000000-0000-4000-8000-000000000008','92000000-0000-4000-8000-000000000009') LOOP
  PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
  PERFORM approve_invoice_mapping_policy(shop,'91000000-0000-4000-8000-000000000004','post-release-fixture','{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','Isolated post-release checkout');
  INSERT INTO menu_items(restaurant_id,name,name_vi,price,invoice_sale_unit,is_visible_public)
   VALUES(shop,'Isolated release meal','Món kiểm thử',10000,'Phần',true) RETURNING id INTO menu;
  INSERT INTO inventory_items(restaurant_id,name,unit,current_stock)
   VALUES(shop,'Isolated release ingredient '||stored_floor,'g',10000) RETURNING id INTO ingredient;
  INSERT INTO menu_recipes(restaurant_id,menu_item_id,ingredient_id,quantity_g) VALUES(shop,menu,ingredient,10);
  INSERT INTO public.tables(restaurant_id,table_number,floor_label)
   VALUES(shop,'98'||left(stored_floor,1)||'6',stored_floor) RETURNING id INTO tab;
  SELECT token INTO qr FROM admin_generate_table_qr(tab);
  PERFORM set_config('request.jwt.claim.sub','',true);
  client_request:=gen_random_uuid();
  result:=qr_place_order(qr,jsonb_build_array(jsonb_build_object('menu_item_id',menu,'quantity',2,'is_takeout',false)),client_request,true,NULL);
  retry:=qr_place_order(qr,jsonb_build_array(jsonb_build_object('menu_item_id',menu,'quantity',2,'is_takeout',false)),client_request,true,NULL);
  oid:=(result->>'order_id')::uuid;
  ASSERT oid IS NOT NULL AND retry->>'order_id'=oid::text,'checkout retry duplicated the order';
  ASSERT (SELECT count(*)=1 AND sum(quantity)=2 FROM order_items WHERE order_id=oid);
  SELECT id,queue_id INTO item,queue FROM emergency_fulfillment_items WHERE order_id=oid;
  ASSERT (SELECT kitchen_direct_to_floor=direct FROM emergency_order_queue WHERE id=queue);
  allocation:=jsonb_build_array(jsonb_build_object('item_id',item,'queue_id',queue,'source_kind','base','quantity',2));
  actor:=CASE WHEN direct THEN '92000000-0000-4000-8000-000000000001' ELSE '92000000-0000-4000-8000-000000000006' END;
  PERFORM set_config('request.jwt.claim.sub',actor,true);
  IF direct THEN
   PERFORM kds_record_station_progress_v3(item,'base','kitchen_started',1,gen_random_uuid());
   ASSERT (SELECT kitchen_started_quantity=1 AND kitchen_done_quantity=0 AND tray_dispatched_quantity=0 FROM emergency_fulfillment_items WHERE id=item);
   ASSERT NOT EXISTS(SELECT 1 FROM emergency_floor_ready_lots WHERE order_item_id IN(SELECT id FROM order_items WHERE order_id=oid));
   ASSERT NOT EXISTS(SELECT 1 FROM emergency_station_assignments WHERE restaurant_id=shop AND station_type='tray' AND is_active);
  END IF;
  request:=gen_random_uuid();
  PERFORM kds_complete_kitchen_batch_v1(request,allocation);
  PERFORM kds_complete_kitchen_batch_v1(request,allocation);
  ASSERT (SELECT kitchen_done_quantity=2 AND tray_dispatched_quantity=CASE WHEN direct THEN 2 ELSE 0 END FROM emergency_fulfillment_items WHERE id=item);
  IF NOT direct THEN
   PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000008',true);
   BEGIN
    PERFORM kds_complete_customer_delivery_batch_v1(gen_random_uuid(),allocation);
    RAISE EXCEPTION 'unready floor served food';
   EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM<>'unready floor served food'; END;
   PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000007',true);
   request:=gen_random_uuid();
   PERFORM kds_dispatch_tray_floor_batch_v1(request,'1F',allocation);
   PERFORM kds_dispatch_tray_floor_batch_v1(request,'1F',allocation);
  END IF;
  PERFORM set_config('request.jwt.claim.sub',wrong_actor,true);
  BEGIN
   PERFORM kds_complete_customer_delivery_batch_v1(gen_random_uuid(),allocation);
   RAISE EXCEPTION 'wrong-floor delivery accepted';
  EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM<>'wrong-floor delivery accepted'; END;
  actor:=floor_actor;
  PERFORM set_config('request.jwt.claim.sub',actor,true);
  request:=gen_random_uuid();
  PERFORM kds_complete_customer_delivery_batch_v1(request,allocation);
  PERFORM kds_complete_customer_delivery_batch_v1(request,allocation);
  ASSERT (SELECT floor_served_quantity=2 FROM emergency_fulfillment_items WHERE id=item);
  PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
  IF direct THEN
   UPDATE order_items SET status='served',created_at=now()-interval '30 minutes' WHERE order_id=oid;
   INSERT INTO qr_order_display_states(order_id,restaurant_id,table_id,visible_from,display_version,all_served_at,reset_due_at,reset_applied_at)
   VALUES(oid,shop,tab,now()-interval '5 minutes',1,now()-interval '15 minutes',now()-interval '5 minutes',now()-interval '5 minutes')
   ON CONFLICT(order_id) DO UPDATE SET visible_from=EXCLUDED.visible_from,display_version=1,
    all_served_at=EXCLUDED.all_served_at,reset_due_at=EXCLUDED.reset_due_at,reset_applied_at=EXCLUDED.reset_applied_at;
   result:=qr_get_active_order(qr);
   ASSERT (result->>'active')::boolean AND result->>'order_id'=oid::text AND jsonb_array_length(result->'items')=1 AND (result->'items'->0->>'quantity')::integer=2,
    'served unpaid order disappeared after display reset';
  END IF;
  own_cashier:=CASE WHEN direct THEN '92000000-0000-4000-8000-000000000101' ELSE '92000000-0000-4000-8000-000000000102' END;
  foreign_cashier:=CASE WHEN direct THEN '92000000-0000-4000-8000-000000000102' ELSE '92000000-0000-4000-8000-000000000101' END;
  PERFORM set_config('request.jwt.claim.sub',foreign_cashier,true);
  BEGIN
   PERFORM process_payment(oid,shop,10000,'CASH');
   RAISE EXCEPTION 'cross-store cashier accepted';
  EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM<>'cross-store cashier accepted'; END;
  ASSERT NOT EXISTS(SELECT 1 FROM payments WHERE order_id=oid),'unauthorized payment left a row';
  PERFORM set_config('request.jwt.claim.sub',own_cashier,true);
  PERFORM process_payment(oid,shop,10000,'CASH');
  ASSERT (SELECT status<>'completed' FROM orders WHERE id=oid);
  ASSERT (SELECT current_stock=10000 FROM inventory_items WHERE id=ingredient);
  PERFORM process_payment(oid,shop,11600,'BANKTRANSFER');
  ASSERT (SELECT status='completed' FROM orders WHERE id=oid);
  ASSERT (SELECT count(*)=2 AND sum(amount)=21600 FROM payments WHERE order_id=oid);
  ASSERT (SELECT current_stock=9980 FROM inventory_items WHERE id=ingredient);
  ASSERT (SELECT count(*)=1 AND sum(quantity_g)=-20 FROM inventory_transactions WHERE reference_id IN(SELECT id FROM order_items WHERE order_id=oid));
  BEGIN
   PERFORM process_payment(oid,shop,11600,'BANKTRANSFER');
   RAISE EXCEPTION 'payment replay accepted';
  EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='ORDER_NOT_PAYABLE',SQLERRM; END;
  ASSERT (SELECT count(*)=1 AND sum(dispatch_attempts)=0 AND bool_and(sent_at IS NULL) FROM meinvoice_jobs WHERE order_id=oid);
  ASSERT (qr_get_active_order(qr)->>'active')::boolean=false;
  RAISE NOTICE 'STORE_CHECKOUT_HANDOFF_PAYMENT=PASS store=% direct=% stored_floor=% cashier=% total=21600 stock_once=20 external_dispatch=0',shop,direct,stored_floor,own_cashier;
 END LOOP;
END $$;
ROLLBACK;
