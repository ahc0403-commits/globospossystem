-- Real current-schema integration fixture; never use production business rows.
BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
DO $test$
DECLARE shop uuid:='8bc9eef5-dcd5-46b1-b931-23f77132322c'; other uuid:='273b057e-3b69-46e3-93c1-6194c2802849';
 ids uuid[]; ingredients uuid[]; cat uuid:=gen_random_uuid(); workbook_categories jsonb; workbook_items jsonb; pid uuid; duplicate_id uuid; combo uuid; payload jsonb;
 selected text; key text; result jsonb; snap jsonb; m public.menu_items; menu public.menu_items; tab uuid; o public.orders; n int;
BEGIN
 UPDATE public.store_lifecycle SET state='active' WHERE restaurant_id IN(shop,other);
 PERFORM public.approve_invoice_mapping_policy(shop,'91000000-0000-4000-8000-000000000004','kimchi-fixture',
  '{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','isolated kimchi revision');
 INSERT INTO public.menu_categories(id,restaurant_id,name,name_ko,name_vi,name_en) VALUES(cat,shop,'Stew','찌개','Canh','Stew');
 WITH inserted AS (INSERT INTO public.inventory_items(restaurant_id,name,current_stock)
 VALUES(shop,'Common',10000),(shop,'Pork',10000),(shop,'Seafood',10000),(shop,'Tuna',10000) RETURNING id,name) SELECT array_agg(id ORDER BY name) INTO ingredients FROM inserted;
 -- Stable explicit fixture IDs are unrelated to any operational menu IDs.
 ids:=ARRAY[gen_random_uuid(),gen_random_uuid(),gen_random_uuid()];
 INSERT INTO public.menu_items(id,restaurant_id,category_id,name,name_ko,name_vi,name_en,price,invoice_sale_unit,is_visible_public)
 SELECT ids[i],shop,cat,x.n,x.n,'Canh fixture','Stew fixture',CASE WHEN i=2 THEN 69000 ELSE 59000 END,'Phần',true
 FROM unnest(ARRAY['돼지고기 김치찌개 (쌀밥포함)','해물 김치찌개 (쌀밥포함)','참치 김치찌개 (쌀밥포함)']) WITH ORDINALITY x(n,i);
 INSERT INTO public.menu_recipes(restaurant_id,menu_item_id,ingredient_id,quantity_g)
 SELECT shop,id,ingredients[1],100 FROM unnest(ids) id;
 INSERT INTO public.menu_recipes(restaurant_id,menu_item_id,ingredient_id,quantity_g)
 SELECT shop,ids[i],ingredients[i+1],50 FROM generate_series(1,3)i;
 INSERT INTO public.menu_items(restaurant_id,category_id,name,name_ko,name_vi,name_en,price,invoice_sale_unit,is_visible_public)
 VALUES(shop,cat,'Duplicate','돼지고기 김치찌개 (쌀밥포함)','Duplicate','Duplicate',59000,'Phần',true) RETURNING id INTO duplicate_id;
 INSERT INTO public.menu_items(restaurant_id,category_id,name,name_ko,name_vi,name_en,price,invoice_sale_unit,is_visible_public,is_combo)
 VALUES(shop,cat,'Combo','Combo','Combo','Combo',100000,'Phần',true,true) RETURNING id INTO combo;
 INSERT INTO public.menu_combo_components(restaurant_id,combo_menu_item_id,component_menu_item_id,quantity) VALUES(shop,combo,ids[3],1);
 payload:=jsonb_build_array(
  jsonb_build_object('menu_id',ids[1],'value_id','pork','name_ko','돼지고기','name_vi','Thịt heo','name_en','Pork'),
  jsonb_build_object('menu_id',ids[2],'value_id','seafood','name_ko','해산물','name_vi','Hải sản','name_en','Seafood'),
  jsonb_build_object('menu_id',ids[3],'value_id','tuna','name_ko','참치','name_vi','Cá ngừ','name_en','Tuna'));
 result:=public.admin_consolidate_kimchi_jjigae(shop,payload);pid:=(result->>'menu_id')::uuid;
 SELECT * INTO m FROM public.menu_items WHERE id=pid;
 ASSERT m.price=59000 AND m.name_ko='김치찌개 (쌀밥포함)' AND NOT m.meal_choices,'PARENT_INVENTED_OPTIONS_OR_PRICE';
 ASSERT m.choice_definition->'groups'->0->>'min'='1' AND m.choice_definition->'groups'->0->>'max'='1','PROTEIN_NOT_SINGLE_REQUIRED';
 ASSERT (SELECT bool_and(catalog_parent_id=pid AND is_available AND NOT is_archived) FROM public.menu_items WHERE id=ANY(ids)),'SOURCE_COMPATIBILITY_LOST';
 ASSERT (SELECT catalog_parent_id=pid FROM public.menu_items WHERE id=duplicate_id),'DUPLICATE_STILL_STANDALONE';
 ASSERT (SELECT component_menu_item_id=ids[3] FROM public.menu_combo_components WHERE combo_menu_item_id=combo),'COMBO_SOURCE_REPLACED';
 ASSERT (SELECT count(*)=6 FROM public.menu_recipes WHERE menu_item_id=ANY(ids)),'SOURCE_RECIPE_CHANGED';
 ASSERT public.admin_consolidate_kimchi_jjigae(shop,payload)->>'idempotent'='true','CONSOLIDATION_RETRY_DUPLICATES_PARENT';
 ASSERT public.admin_consolidate_kimchi_jjigae(shop,NULL)->>'menu_id'=pid::text,'ADMIN_AUTO_SELECTION_CHANGED_SOURCE';
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(shop,'9899','1F') RETURNING id INTO tab;
 key:=gen_random_uuid()::text;
 INSERT INTO public.table_qr_tokens(restaurant_id,table_id,token) VALUES(shop,tab,key);
 result:=public.qr_get_menu(key);
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(result->'items') x WHERE x->>'id'=pid::text),'QR_PARENT_MISSING';
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(result->'items') x WHERE (x->>'id')::uuid=ANY(ids)),'QR_SOURCE_STILL_STANDALONE';
 ASSERT (SELECT count(*)=1 FROM jsonb_array_elements(result->'items') x WHERE x->>'id'=combo::text),'QR_COMBO_DISABLED';
 BEGIN PERFORM public.menu_choice_snapshot(to_jsonb(m),NULL,'pos'); RAISE EXCEPTION 'REQUIRED_PROTEIN_NOT_ENFORCED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'MENU_SELECTION_%' THEN RAISE; END IF; END;
 FOR n IN 1..3 LOOP
  selected:=(ARRAY['pork','seafood','tuna'])[n];
  key:=jsonb_build_object('schema',2,'revision',md5(m.menu_option_key),'selected',jsonb_build_array(jsonb_build_object('value_id',selected,'quantity',1)))::text;
  snap:=public.menu_choice_snapshot(to_jsonb(m),key,'pos');
  ASSERT (snap->>'unit_price')::numeric=CASE WHEN n=2 THEN 69000 ELSE 59000 END,'VARIANT_PRICE_CHANGED';
  INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(shop,(9800+n)::text,'1F') RETURNING id INTO tab;
  o:=public.create_order(shop,tab,jsonb_build_array(jsonb_build_object('menu_item_id',pid,'menu_option_key',key,'quantity',1)));
  ASSERT (SELECT count(*)=2 AND sum(quantity)=150 FROM public.order_choice_consumption(o.id,shop)),'VARIANT_RECIPE_CHANGED';
  ASSERT (SELECT sum(quantity)=50 FROM public.order_choice_consumption(o.id,shop) WHERE ingredient_id=ingredients[n+1]),'WRONG_PROTEIN_CONSUMED';
 END LOOP;
 SELECT * INTO menu FROM public.menu_items WHERE id=ids[1];
 BEGIN PERFORM public.validate_menu_option_batch(shop,jsonb_build_array(jsonb_build_object('menu_item_id',menu.id,'menu_option_key',menu.menu_option_key,'quantity',1)),'pos'); RAISE EXCEPTION 'STALE_SOURCE_CART_ALLOWED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'MENU_ITEM_PRICE_INVALID' THEN RAISE; END IF; END;
 BEGIN PERFORM public.admin_consolidate_kimchi_jjigae(other,payload); RAISE EXCEPTION 'OTHER_STORE_SOURCES_ALLOWED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'MENU_SELECTION_DEFINITION_INVALID' THEN RAISE; END IF; END;
 SELECT jsonb_agg(jsonb_build_object('store_id',shop,'category_id',id,'name_ko',name_ko,'name_vi',name_vi,'name_en',name_en,'sort_order',sort_order))
 INTO workbook_categories FROM public.menu_categories WHERE restaurant_id=shop;
 SELECT jsonb_agg(jsonb_build_object('store_id',shop,'item_id',id,'category_id',category_id,
  'name_ko',name_ko,'name_vi',name_vi,'name_en',name_en,'price',price,'is_available',is_available,
  'is_visible_public',is_visible_public,'sort_order',sort_order)) INTO workbook_items FROM public.menu_items
  WHERE restaurant_id=shop AND catalog_parent_id IS NULL;
 PERFORM public.admin_update_menu_workbook_i18n(shop,workbook_categories,workbook_items);
 ASSERT (SELECT bool_and(catalog_parent_id=pid AND is_available AND NOT is_archived) FROM public.menu_items WHERE id=ANY(ids)),'WORKBOOK_ARCHIVED_COMPATIBILITY_SOURCES';
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000006',true);
 BEGIN PERFORM public.admin_consolidate_kimchi_jjigae(shop,payload); RAISE EXCEPTION 'KITCHEN_REGISTERED_MENU';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'ADMIN_MUTATION_FORBIDDEN' THEN RAISE; END IF; END;
 RAISE NOTICE 'KIMCHI_CONSOLIDATION_CURRENT=PASS prices recipes single_choice idempotency preserved_combo stale_cart tenant_role';
END $test$;
ROLLBACK;
