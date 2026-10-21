-- Execute against the isolated current-schema fixture, before AND after upgrade.
-- Real SQL functions/triggers are exercised; only realtime.send is a local sink.
BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
DO $$ DECLARE
 j uuid:='273b057e-3b69-46e3-93c1-6194c2802849';
 b uuid:='8bc9eef5-dcd5-46b1-b931-23f77132322c';
 jm uuid; bm uuid; jt uuid; bt uuid; jo uuid; bo uuid; ji uuid; bi uuid;
 jq uuid; bq uuid; jp uuid; bp uuid; request uuid; result jsonb; allocation jsonb;
BEGIN
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(j,'1101','2F') RETURNING id INTO jt;
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(b,'101','1F') RETURNING id INTO bt;
 PERFORM public.approve_invoice_mapping_policy(j,'91000000-0000-4000-8000-000000000004','operating-fixture',
  '{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','isolated fixture approval');
 PERFORM public.approve_invoice_mapping_policy(b,'91000000-0000-4000-8000-000000000004','operating-fixture',
  '{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','isolated fixture approval');
 INSERT INTO public.menu_items(restaurant_id,name,name_vi,invoice_sale_unit,price)
 VALUES(j,'Operating fixture J','Món thử J','Phần',10000) RETURNING id INTO jm;
 INSERT INTO public.menu_items(restaurant_id,name,name_vi,invoice_sale_unit,price)
 VALUES(b,'Operating fixture B','Món thử B','Phần',10000) RETURNING id INTO bm;
 INSERT INTO public.orders(restaurant_id,table_id,status) VALUES(j,jt,'pending') RETURNING id INTO jo;
 INSERT INTO public.orders(restaurant_id,table_id,status) VALUES(b,bt,'pending') RETURNING id INTO bo;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,display_name,quantity,unit_price,status)
 VALUES(j,jo,jm,'Operating fixture J',2,10000,'pending') RETURNING id INTO ji;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,display_name,quantity,unit_price,status)
 VALUES(b,bo,bm,'Operating fixture B',2,10000,'pending') RETURNING id INTO bi;
 SELECT id,queue_id INTO jp,jq FROM public.emergency_fulfillment_items WHERE order_item_id=ji;
 SELECT id,queue_id INTO bp,bq FROM public.emergency_fulfillment_items WHERE order_item_id=bi;
 ASSERT jp IS NOT NULL AND bp IS NOT NULL,'KDS lines missing';
 ASSERT (SELECT kitchen_direct_to_floor FROM public.emergency_order_queue WHERE id=jq);
 ASSERT NOT (SELECT kitchen_direct_to_floor FROM public.emergency_order_queue WHERE id=bq);
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_station_assignments WHERE restaurant_id=j AND station_type='tray' AND is_active);
 ASSERT (SELECT floor_label='2F' FROM public.emergency_station_assignments WHERE user_id='93000000-0000-4000-8000-000000000003');

 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000001',true);
 result:=public.kds_record_station_progress_v3(jp,'base','kitchen_started',1,gen_random_uuid());
 ASSERT (SELECT kitchen_started_quantity=1 AND kitchen_done_quantity=0 AND tray_dispatched_quantity=0
  FROM public.emergency_fulfillment_items WHERE id=jp),'start published ready food';
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_floor_ready_lots WHERE order_item_id=ji),'start created floor lot';
 request:=gen_random_uuid();
 allocation:=jsonb_build_array(jsonb_build_object('item_id',jp,'queue_id',jq,'source_kind','base','quantity',2));
 result:=public.kds_complete_kitchen_batch_v1(request,allocation);
 PERFORM public.kds_complete_kitchen_batch_v1(request,allocation);
 ASSERT (SELECT kitchen_started_quantity=2 AND kitchen_done_quantity=2 AND tray_dispatched_quantity=2 AND floor_served_quantity=0
  FROM public.emergency_fulfillment_items WHERE id=jp),'explicit handoff quantity changed';
 ASSERT (SELECT sum(ready_quantity)=2 FROM public.emergency_floor_ready_lots WHERE order_item_id=ji),'ready lot duplicated';
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000003',true);
 PERFORM public.kds_complete_customer_delivery_batch_v1(gen_random_uuid(),allocation);
 ASSERT (SELECT floor_served_quantity=2 FROM public.emergency_fulfillment_items WHERE id=jp);

 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000006',true);
 allocation:=jsonb_build_array(jsonb_build_object('item_id',bp,'queue_id',bq,'source_kind','base','quantity',2));
 PERFORM public.kds_complete_kitchen_batch_v1(gen_random_uuid(),allocation);
 ASSERT (SELECT kitchen_done_quantity=2 AND tray_dispatched_quantity=0 FROM public.emergency_fulfillment_items WHERE id=bp), 'Bunsik checker bypassed';
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000007',true);
 PERFORM public.kds_dispatch_tray_floor_batch_v1(gen_random_uuid(),'1F',allocation);
 ASSERT (SELECT tray_dispatched_quantity=2 AND floor_served_quantity=0 FROM public.emergency_fulfillment_items WHERE id=bp);
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000008',true);
 PERFORM public.kds_complete_customer_delivery_batch_v1(gen_random_uuid(),allocation);
 ASSERT (SELECT floor_served_quantity=2 FROM public.emergency_fulfillment_items WHERE id=bp);
END $$;
SELECT 'OPERATING_EXISTING_STORE_FLOWS=PASS';
ROLLBACK;
