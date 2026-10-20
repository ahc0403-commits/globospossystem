\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE target uuid:='273b057e-3b69-46e3-93c1-6194c2802849'; other uuid:='8bc9eef5-dcd5-46b1-b931-23f77132322c';
 cat uuid; small public.menu_items; large public.menu_items; fixed public.menu_items;
 tid uuid; oid uuid; sid uuid; mid uuid; queue uuid; result jsonb; rows jsonb; allocations jsonb; original jsonb;
BEGIN
 INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at)
 VALUES('92000000-0000-4000-8000-000000000099','menu-lab@internal.invalid','00000000-0000-0000-0000-000000000000','authenticated','authenticated',now());
 INSERT INTO public.users(auth_id,restaurant_id,role,full_name)
 VALUES('92000000-0000-4000-8000-000000000099',target,'super_admin','Menu lab');
 PERFORM set_config('request.jwt.claims','{"sub":"92000000-0000-4000-8000-000000000099","role":"authenticated"}',true);
 INSERT INTO public.menu_categories(restaurant_id,name,name_ko,name_vi,name_en) VALUES(target,'Menu lab','메뉴','Món','Menu') RETURNING id INTO cat;
 small:=public.admin_create_menu_item_with_options(target,cat,'짬뽕','Mì cay','Spicy noodles',null,10000,'{"portion_code":"S","spice_level":"spicy"}');
 large:=public.admin_create_menu_item_with_options(target,cat,'짬뽕','Mì cay','Spicy noodles',null,18000,'{"portion_code":"L","spice_level":"spicy"}');
 ASSERT small.id<>large.id AND small.name LIKE 'S · 🌶 매운 메뉴 · %';
 ASSERT large.name_vi LIKE 'L · 🌶 Món cay · %';
 ASSERT small.option_base_names->>'name_ko'='짬뽕';
 fixed:=public.admin_create_menu_item_with_options(target,cat,'기존','Cũ','Old',null,12000,'{}');
 ASSERT fixed.name='기존' AND fixed.spice_level='unknown';
 BEGIN
  PERFORM public.admin_create_menu_item_with_options(target,cat,'invalid','invalid','invalid',null,10000,'{"portion_code":"M"}');
  RAISE EXCEPTION 'INVALID_SIZE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='MENU_ITEM_PRICE_INVALID',SQLERRM; END;
 ASSERT NOT EXISTS(SELECT 1 FROM public.menu_items WHERE name='invalid');
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(target,'991','3F') RETURNING id INTO tid;
 INSERT INTO public.orders(restaurant_id,table_id,status) VALUES(target,tid,'pending') RETURNING id INTO oid;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,label,display_name,quantity,unit_price)
 VALUES(target,oid,small.id,small.name,small.name,1,10000),(target,oid,large.id,large.name,large.name,1,18000);
 ASSERT (SELECT sum(quantity*unit_price)=28000 AND count(*)=2 FROM public.order_items WHERE order_id=oid);
 SELECT id,menu_option_snapshot INTO sid,original FROM public.order_items WHERE order_id=oid AND menu_item_id=small.id;
 SELECT id INTO mid FROM public.order_items WHERE order_id=oid AND menu_item_id=large.id;
 ASSERT original->>'portion_code'='S' AND original->>'spice_level'='spicy';
 BEGIN
  INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,label,display_name,quantity,unit_price) VALUES(target,oid,small.id,small.name,small.name,1,1);
  RAISE EXCEPTION 'TAMPERED_PRICE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='MENU_ITEM_PRICE_INVALID',SQLERRM; END;
 BEGIN
  INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,label,display_name,quantity,unit_price) VALUES(other,oid,small.id,small.name,small.name,1,10000);
  RAISE EXCEPTION 'CROSS_STORE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM IS NOT NULL AND SQLERRM<>'CROSS_STORE_ACCEPTED'; END;
 PERFORM public.admin_update_menu_item_with_options(small.id,'짬뽕 새이름','Mì mới','New noodles',null,11000,'{"portion_code":"S","spice_level":"not_spicy"}');
 ASSERT (SELECT menu_option_snapshot=original AND label=small.name AND unit_price=10000 FROM public.order_items WHERE id=sid);
 PERFORM set_config('request.jwt.claims','{"sub":"92000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
 result:=public.get_emergency_station_snapshot();
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(result->'orders')o,jsonb_array_elements(o->'items')i
  WHERE i->>'order_item_id'=sid::text AND i->'menu_option_snapshot'->>'portion_code'='S' AND i->>'name_ko'=small.name_ko),result::text;
 SELECT jsonb_agg(jsonb_build_object('item_id',id,'queue_id',queue_id,'source_kind','base','quantity',1)) INTO allocations FROM public.emergency_fulfillment_items WHERE order_id=oid;
 PERFORM public.kds_complete_kitchen_batch_v1(gen_random_uuid(),allocations);
 PERFORM set_config('request.jwt.claims','{"sub":"92000000-0000-4000-8000-000000000005","role":"authenticated"}',true);
 result:=public.get_emergency_station_snapshot();
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(result->'orders')o,jsonb_array_elements(o->'items')i WHERE i->>'order_item_id'=mid::text AND i->'menu_option_snapshot'->>'portion_code'='L');
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_tray_ready_lots WHERE order_id=oid);
 PERFORM set_config('request.jwt.claims','{"sub":"92000000-0000-4000-8000-000000000099","role":"authenticated"}',true);
 -- Missing option columns in an old workbook preserve registered choices.
 PERFORM public.menu_apply_option_workbook(target,jsonb_build_array(jsonb_build_object('item_id',large.id)));
 ASSERT (SELECT portion_code='L' AND spice_level='spicy' FROM public.menu_items WHERE id=large.id);
 -- Full import creates separate S/L IDs with correct base names and prices.
 rows:=jsonb_build_array(jsonb_build_object('source_row',2,'category_name','Excel lab','category_sort_order',1,'name','탕수육','name_vi','Thịt','price',10000,'sort_order',0,'is_available',true,'is_visible_public',true,'portion_code','S','spice_level','not_spicy'),
 jsonb_build_object('source_row',3,'category_name','Excel lab','category_sort_order',1,'name','탕수육','name_vi','Thịt','price',20000,'sort_order',1,'is_available',true,'is_visible_public',true,'portion_code','L','spice_level','not_spicy'));
 result:=public.admin_import_menu_items(target,rows);
 ASSERT (SELECT count(*)=2 AND count(DISTINCT portion_code)=2 FROM public.menu_items WHERE restaurant_id=target AND option_base_names->>'name'='탕수육');
 ASSERT NOT EXISTS(SELECT 1 FROM public.menu_items WHERE name LIKE '% · S% · S%' OR name LIKE '% · L% · L%' OR name_en LIKE '%Spicy dish%Spicy dish%' OR name_en LIKE '%Not spicy%Not spicy%');
 -- Stale or missing keys never change a registered choice silently.
 BEGIN
  PERFORM public.validate_menu_option_batch(target,jsonb_build_array(jsonb_build_object('menu_item_id',small.id,'menu_option_key',small.menu_option_key)),'direct');
  RAISE EXCEPTION 'STALE_OPTIONS_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='DIRECT_ORDER_MENU_CHANGED',SQLERRM; END;
 BEGIN
  PERFORM public.validate_menu_option_batch(target,jsonb_build_array(jsonb_build_object('menu_item_id',large.id)),'qr');
  RAISE EXCEPTION 'MISSING_OPTIONS_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='QR_MENU_ITEM_UNAVAILABLE',SQLERRM; END;
 -- The real QR path validates and inserts S/L together in a single batch.
 SELECT * INTO small FROM public.menu_items WHERE id=small.id;
 UPDATE public.menu_items SET is_visible_public=true WHERE id IN(small.id,large.id);
 INSERT INTO public.table_qr_tokens(restaurant_id,table_id,token) VALUES(target,tid,'menu-option-lab-token-20261020');
 result:=public.qr_get_menu('menu-option-lab-token-20261020');
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(result->'items')i WHERE i->>'id'=large.id::text AND i->>'menu_option_key'=large.menu_option_key),result::text;
 rows:=jsonb_build_array(jsonb_build_object('menu_item_id',small.id,'quantity',1,'menu_option_key',small.menu_option_key),
   jsonb_build_object('menu_item_id',large.id,'quantity',1,'menu_option_key',large.menu_option_key));
 result:=public.qr_place_order('menu-option-lab-token-20261020',rows,gen_random_uuid(),true,oid);
 ASSERT (SELECT count(*)=4 AND sum(quantity*unit_price)=57000 FROM public.order_items WHERE order_id=oid),result::text;
 -- Public direct preparation uses the same registered choices and server price.
 result:=public.direct_order_prepare_combo_items(target,rows);
 ASSERT jsonb_array_length(result)=2 AND (result->0->>'unit_price')::numeric=11000 AND (result->1->>'unit_price')::numeric=18000,result::text;
 -- POS creation and supplemental items keep all snapshots in one batch.
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(target,'992','1F') RETURNING id INTO tid;
 SELECT id INTO oid FROM public.create_order(target,tid,rows);
 PERFORM public.add_items_to_order(oid,target,rows);
 ASSERT (SELECT count(*)=4 AND sum(quantity*unit_price)=58000 AND bool_and(menu_option_snapshot<>'{}') FROM public.order_items WHERE order_id=oid);
 -- Partial table moves preserve an existing option/price after catalog edits.
 SELECT order_id INTO oid FROM public.order_items WHERE id=sid;
 UPDATE public.order_items SET quantity=2 WHERE id=sid;
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(target,'993','3F') RETURNING id INTO tid;
 result:=public.cashier_move_order_items(target,oid,tid,jsonb_build_array(jsonb_build_object('item_id',sid,'quantity',1,'expected_quantity',2)),gen_random_uuid());
 ASSERT (SELECT count(*)=2 AND bool_and(menu_option_snapshot=original) AND bool_and(unit_price=10000) FROM public.order_items WHERE menu_item_id=small.id AND unit_price=10000),result::text;
 BEGIN
  UPDATE public.order_items SET menu_option_snapshot='{"portion_code":"L"}' WHERE id=sid;
  RAISE EXCEPTION 'ORDER_OPTION_REWRITE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='ITEM_NOT_EDITABLE',SQLERRM; END;
 -- Physical and digital receipts retain the original Vietnamese choice.
 INSERT INTO public.print_jobs(restaurant_id,order_id,copy_type,batch_no,payload)
 VALUES(target,oid,'kitchen',99,jsonb_build_object('items',jsonb_build_array(jsonb_build_object('item_id',sid,'label','must be replaced')))) RETURNING payload INTO result;
 ASSERT result->'items'->0->>'label'=original->>'name_vi',result::text;
 INSERT INTO public.digital_receipts(restaurant_id,order_id,receipt_number,snapshot)
 VALUES(target,oid,'MENU-LAB-RECEIPT',jsonb_build_object('items',(SELECT jsonb_agg(jsonb_build_object('item_id',id,'label','must be replaced') ORDER BY created_at,id) FROM public.order_items WHERE order_id=oid AND status<>'cancelled'))) RETURNING snapshot INTO result;
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(result->'items')i WHERE i->>'item_id'=sid::text AND i->>'label'=original->>'name_vi'),result::text;
 ASSERT NOT EXISTS(SELECT 1 FROM public.print_jobs WHERE order_id=oid AND batch_no=99 AND copy_type='tray');
 -- A fixed combo component also keeps structured S/L and spice snapshots.
 fixed:=public.admin_create_menu_item_with_options(target,cat,'콤보','Bộ','Combo',null,25000,'{}');
 PERFORM public.admin_set_menu_combo(fixed.id,true,jsonb_build_array(jsonb_build_object('menu_item_id',small.id,'quantity',1)),0);
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,label,display_name,quantity,unit_price)
 VALUES(target,oid,fixed.id,'콤보','콤보',1,25000) RETURNING id INTO mid;
 ASSERT (SELECT menu_option_snapshot->'components'->(small.id::text)->>'portion_code'='S' FROM public.order_items WHERE id=mid);
 PERFORM set_config('request.jwt.claims','{"sub":"92000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
 result:=public.get_emergency_station_snapshot();
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(result->'orders')o,jsonb_array_elements(o->'items')i WHERE i->>'order_item_id'=mid::text AND i->>'source_kind'='combo_component' AND i->'menu_option_snapshot'->>'portion_code'='S'),result::text;
 PERFORM set_config('request.jwt.claims','{"sub":"92000000-0000-4000-8000-000000000099","role":"authenticated"}',true);
 -- Clearing options also invalidates the previous registered key.
 PERFORM public.menu_apply_registered_options(large.id,'{}');
 BEGIN
  PERFORM public.validate_menu_option_batch(target,jsonb_build_array(jsonb_build_object('menu_item_id',large.id,'menu_option_key',large.menu_option_key)),'direct');
  RAISE EXCEPTION 'CLEARED_OPTIONS_ACCEPTED_OLD_KEY';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='DIRECT_ORDER_MENU_CHANGED',SQLERRM; END;
 -- A kitchen account cannot create or change menu choices.
 PERFORM set_config('request.jwt.claims','{"sub":"92000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
 BEGIN
  PERFORM public.menu_apply_registered_options(small.id,'{"portion_code":"L"}');
  RAISE EXCEPTION 'KITCHEN_MENU_EDIT_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='ADMIN_MUTATION_FORBIDDEN',SQLERRM; END;
END $$;
ROLLBACK;
