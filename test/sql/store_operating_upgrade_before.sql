CREATE SCHEMA operating_test;
CREATE TABLE operating_test.function_baseline AS
 SELECT p.oid::regprocedure::text signature,md5(pg_get_functiondef(p.oid)) hash,
 p.proacl::text acl,p.proowner owner_id,p.prosecdef security_definer,p.proconfig config
 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.prokind='f';
BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
DO $$ DECLARE j uuid:='273b057e-3b69-46e3-93c1-6194c2802849'; m uuid; t uuid; o uuid; i uuid; p uuid; q uuid;
BEGIN
 PERFORM public.approve_invoice_mapping_policy(j,'91000000-0000-4000-8000-000000000004','operating-upgrade',
  '{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','isolated upgrade fixture approval');
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(j,'1111','2F') RETURNING id INTO t;
 INSERT INTO public.menu_items(restaurant_id,name,name_vi,invoice_sale_unit,price)
 VALUES(j,'Upgrade pending menu','Món thử đang chờ','Phần',10000) RETURNING id INTO m;
 INSERT INTO public.orders(restaurant_id,table_id,status) VALUES(j,t,'pending') RETURNING id INTO o;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,display_name,quantity,unit_price,status)
 VALUES(j,o,m,'Upgrade pending menu',3,10000,'pending') RETURNING id INTO i;
 SELECT id,queue_id INTO p,q FROM public.emergency_fulfillment_items WHERE order_item_id=i;
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000001',true);
 PERFORM public.kds_record_station_progress_v3(p,'base','kitchen_started',1,gen_random_uuid());
 PERFORM public.kds_complete_kitchen_batch_v1(gen_random_uuid(),jsonb_build_array(jsonb_build_object(
  'item_id',p,'queue_id',q,'source_kind','base','quantity',1)));
 ASSERT (SELECT kitchen_done_quantity=1 AND floor_served_quantity=0 FROM public.emergency_fulfillment_items WHERE id=p);
END $$;
COMMIT;
CREATE TABLE operating_test.row_baseline(table_name text PRIMARY KEY,hash text);
DO $$ DECLARE name text; h text; BEGIN
 FOREACH name IN ARRAY ARRAY['restaurants','restaurant_settings','users','tables','menu_items','orders','order_items',
  'emergency_station_assignments','emergency_order_queue','emergency_fulfillment_items',
  'emergency_floor_ready_lots','emergency_fulfillment_events','payments','inventory_transactions','menu_invoice_profiles'] LOOP
  EXECUTE format('SELECT md5(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text,''[]'')) FROM public.%I t',name) INTO h;
  INSERT INTO operating_test.row_baseline VALUES(name,h);
 END LOOP;
END $$;
