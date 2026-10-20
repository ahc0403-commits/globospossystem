\set ON_ERROR_STOP on
BEGIN;
DO $$
DECLARE target uuid:='273b057e-3b69-46e3-93c1-6194c2802849'; other uuid:='8bc9eef5-dcd5-46b1-b931-23f77132322c';
 cat uuid; m public.menu_items; l public.menu_items; old_key text; oid uuid; tid uuid; frozen jsonb; items jsonb; result jsonb;
BEGIN
 INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at)
 VALUES('93000000-0000-4000-8000-000000000099','size-lab@internal.invalid','00000000-0000-0000-0000-000000000000','authenticated','authenticated',now());
 INSERT INTO public.users(auth_id,restaurant_id,role,full_name)
 VALUES('93000000-0000-4000-8000-000000000099',target,'super_admin','Size lab');
 PERFORM set_config('request.jwt.claims','{"sub":"93000000-0000-4000-8000-000000000099","role":"authenticated"}',true);
 INSERT INTO public.menu_categories(restaurant_id,name,name_ko,name_vi,name_en) VALUES(target,'Size lab','요리','Món chính','Main') RETURNING id INTO cat;
 -- A single registration owns the prices. Existing financial IDs are projections.
 m:=public.admin_create_menu_item_with_options(target,cat,'탕수육','Thịt chua ngọt','Sweet and sour pork',null,190000,'{"size_prices":{"S":190000,"L":370000}}');
 ASSERT m.size_prices='{"S":190000,"L":370000}'::jsonb AND m.size_parent_id IS NULL;
 SELECT * INTO STRICT l FROM public.menu_items WHERE size_parent_id=m.id;
 ASSERT l.portion_code='L' AND l.price=370000;
 ASSERT (m.menu_option_key::jsonb)->4->>'menu_id'=m.id::text;
 ASSERT (l.menu_option_key::jsonb)->4->>'menu_id'=m.id::text;
 ASSERT (m.menu_option_key::jsonb)->4->'names'->>'name_ko'='탕수육';
 ASSERT (SELECT count(*)=1 FROM public.menu_items WHERE category_id=cat AND size_parent_id IS NULL);
 UPDATE public.menu_items SET is_visible_public=true WHERE id=m.id;
 ASSERT (SELECT is_visible_public FROM public.menu_items WHERE id=l.id);
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(target,'size-991','1F') RETURNING id INTO tid;
 INSERT INTO public.table_qr_tokens(restaurant_id,table_id,token) VALUES(target,tid,'size-lab-token-20261020');
 SELECT * INTO m FROM public.menu_items WHERE id=m.id;
 SELECT * INTO l FROM public.menu_items WHERE id=l.id;
 items:=jsonb_build_array(jsonb_build_object('menu_item_id',m.id,'quantity',1,'menu_option_key',m.menu_option_key),jsonb_build_object('menu_item_id',l.id,'quantity',1,'menu_option_key',l.menu_option_key));
 SELECT id INTO oid FROM public.create_order(target,tid,items);
 ASSERT (SELECT count(*)=2 AND sum(quantity*unit_price)=560000 FROM public.order_items WHERE order_id=oid);
 ASSERT (SELECT count(DISTINCT menu_option_snapshot->>'portion_code')=2 FROM public.order_items WHERE order_id=oid);
 SELECT jsonb_agg(to_jsonb(i) ORDER BY id) INTO frozen FROM public.order_items i WHERE order_id=oid;
 old_key:=l.menu_option_key;
 -- Both prices and names change atomically; the L projection retains its ID.
 m:=public.admin_update_menu_item_with_options(m.id,'탕수육 새이름','Thịt mới','New pork',null,200000,'{"size_prices":{"S":200000,"L":390000},"spice_level":"spicy"}');
 SELECT * INTO l FROM public.menu_items WHERE id=l.id;
 ASSERT m.price=200000 AND l.price=390000 AND l.name_en='L · 🌶 Spicy dish · New pork';
 ASSERT m.size_prices='{"S":200000,"L":390000}'::jsonb;
 ASSERT (SELECT jsonb_agg(to_jsonb(i) ORDER BY id)=frozen FROM public.order_items i WHERE order_id=oid);
 BEGIN
  PERFORM public.validate_menu_option_batch(target,jsonb_build_array(jsonb_build_object('menu_item_id',l.id,'menu_option_key',old_key)),'qr');
  RAISE EXCEPTION 'STALE_SIZE_PRICE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='QR_MENU_ITEM_UNAVAILABLE',SQLERRM; END;
 BEGIN
  UPDATE public.menu_items SET price=1 WHERE id=l.id;
  RAISE EXCEPTION 'INDEPENDENT_SIZE_PRICE_WRITE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='MENU_SIZE_PRICE_MANAGED_BY_PARENT',SQLERRM; END;
 BEGIN
  PERFORM public.admin_update_menu_item_with_options(m.id,'bad','bad','bad',null,1,'{"size_prices":{"S":1,"L":0}}');
  RAISE EXCEPTION 'INVALID_SIZE_PRICE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='MENU_ITEM_PRICE_INVALID',SQLERRM; END;
 ASSERT (SELECT size_prices='{"S":200000,"L":390000}'::jsonb FROM public.menu_items WHERE id=m.id);
 -- New imports have one source row with both prices, never two registrations.
 result:=public.admin_import_menu_items(target,jsonb_build_array(jsonb_build_object('source_row',2,'category_name','Size Excel','category_sort_order',1,'name','라조육','name_vi','Thịt cay','name_en','Spicy pork','price',210000,'size_prices',jsonb_build_object('S',210000,'L',390000),'sort_order',0,'is_available',true,'is_visible_public',true)));
 ASSERT result->>'item_count'='1';
 ASSERT (SELECT count(*)=1 FROM public.menu_items WHERE restaurant_id=target AND option_base_names->>'name'='라조육' AND size_parent_id IS NULL);
 ASSERT (SELECT count(*)=1 FROM public.menu_items WHERE restaurant_id=target AND option_base_names->>'name'='라조육' AND size_parent_id IS NOT NULL);
 -- Clearing sizes archives the legacy L price; existing order snapshots survive.
 m:=public.admin_update_menu_item_with_options(m.id,'단일 탕수육','Thịt','Pork',null,220000,'{"size_prices":{}}');
 ASSERT m.price=220000 AND m.portion_code='';
 ASSERT (SELECT is_archived AND NOT is_available FROM public.menu_items WHERE id=l.id);
 ASSERT (SELECT jsonb_agg(to_jsonb(i) ORDER BY id)=frozen FROM public.order_items i WHERE order_id=oid);
 ASSERT NOT has_function_privilege('authenticated','public.menu_save_size_prices(uuid,jsonb,jsonb)','EXECUTE');
END $$;
ROLLBACK;
SELECT 'MENU_SIZE_PRICES_SQL_TEST=PASS';
