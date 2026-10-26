BEGIN;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',true);
DO $test$
DECLARE shop uuid:='8bc9eef5-dcd5-46b1-b931-23f77132322c'; ids uuid[]; common_id uuid:=gen_random_uuid();
 protein uuid[]:=ARRAY[gen_random_uuid(),gen_random_uuid(),gen_random_uuid()]; payload jsonb; parent uuid;
 cat uuid:=gen_random_uuid(); m public.menu_items; snap jsonb; key text; selected text; n int; combo uuid:=gen_random_uuid();
BEGIN
 ids:=ARRAY[gen_random_uuid(),gen_random_uuid(),gen_random_uuid()];
 INSERT INTO public.menu_categories(id,restaurant_id,name) VALUES(cat,shop,'Fixture');
 INSERT INTO public.inventory_items(id,restaurant_id,name) SELECT id,shop,'Recipe fixture' FROM unnest(protein||common_id) id;
 INSERT INTO public.menu_items(id,restaurant_id,category_id,name,name_ko,name_vi,name_en,price,invoice_sale_unit,is_visible_public)
 SELECT ids[i],shop,cat,name,name,'Canh fixture','Stew fixture',CASE WHEN i=2 THEN 69000 ELSE 59000 END,'Phần',true
 FROM unnest(ARRAY['돼지고기 김치찌개 (쌀밥포함)','해물 김치찌개 (쌀밥포함)','참치 김치찌개 (쌀밥포함)']) WITH ORDINALITY x(name,i);
 INSERT INTO public.menu_recipes SELECT shop,id,common_id,100 FROM unnest(ids) id;
 INSERT INTO public.menu_recipes SELECT shop,ids[i],protein[i],50 FROM generate_series(1,3)i;
 INSERT INTO public.menu_combo_components VALUES(shop,combo,ids[3],1);
 payload:=jsonb_build_array(
  jsonb_build_object('menu_id',ids[1],'value_id','pork','name_ko','돼지고기','name_vi','Thịt heo','name_en','Pork'),
  jsonb_build_object('menu_id',ids[2],'value_id','seafood','name_ko','해산물','name_vi','Hải sản','name_en','Seafood'),
  jsonb_build_object('menu_id',ids[3],'value_id','tuna','name_ko','참치','name_vi','Cá ngừ','name_en','Tuna'));
 parent:=(public.admin_consolidate_kimchi_jjigae(shop,payload)->>'menu_id')::uuid;
 SELECT * INTO m FROM public.menu_items WHERE id=parent;
 ASSERT (SELECT count(*)=1 FROM public.menu_items WHERE restaurant_id=shop AND catalog_parent_id IS NULL),'MULTIPLE_CATALOG_DISHES';
 ASSERT (SELECT bool_and(catalog_parent_id=parent AND is_available AND NOT is_archived) FROM public.menu_items WHERE id=ANY(ids)),'SOURCE_IDENTITIES_RETIRED';
 ASSERT jsonb_array_length(public.direct_order_public_storefront_pre_options(shop::text)->'items')=1,'PUBLIC_CATALOG_NOT_CONSOLIDATED';
 ASSERT (SELECT component_menu_item_id=ids[3] FROM public.menu_combo_components WHERE combo_menu_item_id=combo),'COMBO_CHANGED';
 ASSERT (SELECT count(*)=6 FROM public.menu_recipes WHERE menu_item_id=ANY(ids)),'SOURCE_RECIPES_CHANGED';
 ASSERT (SELECT count(*)=1 AND sum(quantity_g)=100 FROM public.menu_recipes WHERE menu_item_id=parent),'COMMON_RECIPE_CHANGED';
 FOR n IN 1..3 LOOP
  selected:=(ARRAY['pork','seafood','tuna'])[n];
  key:=jsonb_build_object('schema',2,'revision',md5(m.menu_option_key),'selected',jsonb_build_array(jsonb_build_object('value_id',selected,'quantity',1)))::text;
  snap:=public.menu_choice_snapshot(to_jsonb(m),key,'pos');
  ASSERT (snap->>'unit_price')::numeric=CASE WHEN n=2 THEN 69000 ELSE 59000 END,'OPTION_PRICE_CHANGED';
  ASSERT (snap->'recipe_additions'->0->>'ingredient_id')::uuid=protein[n] AND (snap->'recipe_additions'->0->>'quantity_g')::numeric=50,'WRONG_PROTEIN';
 END LOOP;
 ASSERT public.admin_consolidate_kimchi_jjigae(shop,payload)->>'idempotent'='true','PARENT_DUPLICATED_ON_RETRY';
 ASSERT public.admin_consolidate_kimchi_jjigae(shop,NULL)->>'menu_id'=parent::text,'ADMIN_SOURCE_DISCOVERY_CHANGED_MENU';
 BEGIN PERFORM public.admin_consolidate_kimchi_jjigae(gen_random_uuid(),payload); RAISE EXCEPTION 'CROSS_STORE_SOURCES_ACCEPTED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'MENU_SELECTION_DEFINITION_INVALID' THEN RAISE; END IF; END;
 BEGIN PERFORM public.menu_choice_snapshot(to_jsonb(m),NULL,'pos'); RAISE EXCEPTION 'REQUIRED_CHOICE_OMITTED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'MENU_SELECTION_%' THEN RAISE; END IF; END;
 RAISE NOTICE 'KIMCHI_CONSOLIDATION=PASS catalog prices recipes combo identities idempotency tenant required_choice';
END $test$;
ROLLBACK;
