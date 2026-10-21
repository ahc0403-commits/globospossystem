-- Full current-schema fixture: actual registration, intake, snapshots and payment.
BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
CREATE SCHEMA choice_test;
CREATE FUNCTION choice_test.key(catalog text, ids text[]) RETURNS text LANGUAGE sql IMMUTABLE AS $$
 SELECT jsonb_build_object('schema',2,'revision',md5(catalog),'selected',coalesce((SELECT jsonb_agg(jsonb_build_object('value_id',id,'quantity',1) ORDER BY ord) FROM unnest(ids) WITH ORDINALITY x(id,ord)),'[]'))::text;
$$;
DO $$ DECLARE
 shop uuid:='273b057e-3b69-46e3-93c1-6194c2802849'; m public.menu_items; legacy text; ingredient uuid; def jsonb;
 mild text; hot text; payload jsonb; result jsonb; snapshot jsonb; t uuid; o public.orders; oid uuid; item public.order_items; subtotal numeric;
 sid uuid; secret text:=repeat('a',64); rid uuid; combo uuid; quote jsonb; proof uuid; token text; selection text;
BEGIN
 PERFORM public.approve_invoice_mapping_policy(shop,'91000000-0000-4000-8000-000000000004','choices-fixture',
  '{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','isolated choices approval');
 INSERT INTO public.inventory_items(restaurant_id,name,current_stock) VALUES(shop,'Choice ingredient',10000) RETURNING id INTO ingredient;
 INSERT INTO public.menu_items(restaurant_id,name,name_ko,name_vi,name_en,price,invoice_sale_unit,is_visible_public)
 VALUES(shop,'Choice dish','선택 메뉴','Món lựa chọn','Choice dish',10000,'Phần',true) RETURNING * INTO m;
 legacy:=m.menu_option_key;
 ASSERT public.menu_choice_catalog_key(legacy,'{}',10000) IS NOT DISTINCT FROM legacy,'legacy catalog changed';
 def:=jsonb_build_object('schema_version',1,'groups',jsonb_build_array(
  jsonb_build_object('id','spice','name_ko','맵기','name_vi','Độ cay','name_en','Spice','min',1,'max',1,'repeat',false,'channels',jsonb_build_array('pos','qr','direct'),
   'values',jsonb_build_array(
    jsonb_build_object('id','mild','name_ko','안맵게','name_vi','Không cay','name_en','Mild','price_delta',0,'available',true),
    jsonb_build_object('id','hot','name_ko','맵게','name_vi','Cay','name_en','Hot','price_delta',2000,'available',true,
     'recipe_additions',jsonb_build_array(jsonb_build_object('ingredient_id',ingredient,'quantity_g',3))))),
  jsonb_build_object('id','salt','name_ko','짜기','name_vi','Độ mặn','name_en','Salt','min',1,'max',1,'repeat',false,'channels',jsonb_build_array('pos','qr','direct'),
   'values',jsonb_build_array(jsonb_build_object('id','normal','name_ko','중간','name_vi','Vừa','name_en','Normal','price_delta',0,'available',true),
    jsonb_build_object('id','less','name_ko','덜 짜게','name_vi','Ít mặn','name_en','Less salt','price_delta',0,'available',true)))));
 ASSERT public.menu_choice_definition_valid(def);
 ASSERT NOT public.menu_choice_definition_valid(def-'schema_version');
 ASSERT NOT public.menu_choice_definition_valid(jsonb_set(def,'{groups,0,min}','2'));
 ASSERT NOT public.menu_choice_definition_valid(jsonb_set(def,'{groups,0,values,0,price_delta}','-1'));
 ASSERT NOT public.menu_choice_definition_valid(jsonb_set(def,'{groups,0,values,0,id}','"hot"'));
 m:=public.admin_apply_menu_choices(m.id,def);
 ASSERT position('recipe_additions' in m.menu_option_key)=0,'recipe leaked into public catalog';
 ASSERT position(ingredient::text in m.menu_option_key)=0,'ingredient leaked into public catalog';
 INSERT INTO public.menu_recipes(restaurant_id,menu_item_id,ingredient_id,quantity_g) VALUES(shop,m.id,ingredient,10);
 mild:=choice_test.key(m.menu_option_key,ARRAY['mild','less']); hot:=choice_test.key(m.menu_option_key,ARRAY['hot','normal']);
 snapshot:=public.menu_choice_snapshot(to_jsonb(m),hot,'pos');
 ASSERT (snapshot->>'unit_price')::numeric=12000;
 ASSERT snapshot->>'name_ko'='선택 메뉴 [맵게 · 중간]';
 ASSERT snapshot->'recipe_additions'->0->>'quantity_g'='3';
 FOREACH selection IN ARRAY ARRAY[m.menu_option_key,choice_test.key(m.menu_option_key,ARRAY['hot']),choice_test.key(m.menu_option_key,ARRAY['hot','mild','normal']),choice_test.key(m.menu_option_key,ARRAY['bad','normal'])] LOOP
  BEGIN PERFORM public.menu_choice_snapshot(to_jsonb(m),selection,'qr'); RAISE EXCEPTION 'INVALID_CHOICE_ACCEPTED';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT LIKE 'MENU_SELECTION_%' THEN RAISE; END IF; END;
 END LOOP;
 payload:=jsonb_build_array(jsonb_build_object('menu_item_id',m.id,'menu_option_key',mild,'quantity',1),jsonb_build_object('menu_item_id',m.id,'menu_option_key',hot,'quantity',2,'is_takeout',true));
 PERFORM public.validate_menu_option_batch(shop,payload,'pos');
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(shop,'1901','2F') RETURNING id INTO t;
 o:=public.create_order(shop,t,payload);
 ASSERT (SELECT count(*)=2 AND sum(unit_price*quantity)=34000 FROM public.order_items WHERE order_id=o.id),'POS choices merged/repriced';
 ASSERT (SELECT count(*)=1 FROM public.order_items WHERE order_id=o.id AND is_takeout AND unit_price=12000),'takeout selection changed';
 ASSERT (SELECT bool_and(menu_option_snapshot->>'choice_schema'='1') FROM public.order_items WHERE order_id=o.id),'POS snapshot absent';
 ASSERT (SELECT bool_and(display_name LIKE '%[%]%') FROM public.order_items WHERE order_id=o.id),'POS labels missing';
 ASSERT (SELECT sum(quantity)=36 FROM public.order_choice_consumption(o.id,shop)),'base and extra usage wrong';

 UPDATE public.menu_recipes SET quantity_g=999 WHERE menu_item_id=m.id;
 ASSERT (SELECT sum(quantity)=36 FROM public.order_choice_consumption(o.id,shop)),'later recipe edit changed frozen consumption';
 UPDATE public.order_items SET status='served' WHERE order_id=o.id;
 PERFORM public.process_payment(o.id,shop,36720,'CASH');
 ASSERT (SELECT current_stock=9964 FROM public.inventory_items WHERE id=ingredient),'option stock not paid exactly once';
 ASSERT (SELECT count(*)=2 AND sum(quantity_g)=-36 FROM public.inventory_transactions WHERE reference_id IN(SELECT id FROM public.order_items WHERE order_id=o.id)),'option usage not combined with base per line';
 UPDATE public.menu_recipes SET quantity_g=10 WHERE menu_item_id=m.id;
 RAISE NOTICE 'REGISTERED_CHOICES_POS=PASS';
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(shop,'1902','2F') RETURNING id INTO t;
 token:=gen_random_uuid()::text;
 INSERT INTO public.table_qr_tokens(restaurant_id,table_id,token) VALUES(shop,t,token);
 result:=public.qr_place_order(token,payload,gen_random_uuid(),true);
 oid:=(result->>'order_id')::uuid;
 ASSERT (SELECT count(*)=2 AND sum(unit_price*quantity)=34000 FROM public.order_items WHERE order_id=oid),'QR choices merged/repriced';
 ASSERT (SELECT count(*)=1 FROM public.order_items WHERE order_id=oid AND is_takeout AND unit_price=12000),'QR takeout changed';
 ASSERT (SELECT bool_and(menu_option_snapshot->>'choice_schema'='1') FROM public.order_items WHERE order_id=oid),'QR snapshot absent';
 RAISE NOTICE 'REGISTERED_CHOICES_QR=PASS';
 INSERT INTO public.direct_order_storefronts(restaurant_id,public_slug,is_enabled,ordering_hours_enforced,
  bank_bin,bank_account_number,bank_account_holder,accounting_approved_at,accounting_approved_by)
 VALUES(shop,'choice-fixture',true,false,'000000','FIXTURE123','Fixture account',now(),auth.uid())
 ON CONFLICT(restaurant_id) DO UPDATE SET is_paused=false,ordering_hours_enforced=false,minimum_order_amount=0;
 INSERT INTO public.direct_order_sessions(restaurant_id,secret_hash,locale) VALUES(shop,secret,'vi') RETURNING id INTO sid;
 payload:=jsonb_build_object('locale','vi','fulfillment_type','pickup','diner_count',1,'items',payload,
  'address',jsonb_build_object('customer_name','Choice fixture','customer_phone','0901234567','address_source','pickup'));
 rid:=(public.direct_order_public_submit_v3(sid,secret,gen_random_uuid(),payload)->>'request_id')::uuid;
 ASSERT (SELECT count(*)=2 AND sum(unit_price*quantity)=34000 FROM public.direct_order_request_items WHERE request_id=rid),'direct choices merged/repriced';
 result:=public.direct_order_public_status_v11(sid,secret,rid);
 ASSERT jsonb_array_length(result->'items')=2,'public status multiplied lines';
 ASSERT result->'items'->0->>'name_ko'='선택 메뉴 [안맵게 · 덜 짜게]','public selection lost';
 result:=public.direct_order_staff_detail_v8(shop,rid);
 ASSERT jsonb_array_length(result->'items')=2,'staff detail multiplied lines';
 quote:=public.direct_order_staff_quote_with_payment_mode(shop,rid,0,NULL,'customer_direct');
 ASSERT (quote->>'final_total')::numeric=36720,'direct option quote wrong';
 UPDATE public.direct_order_requests SET state='awaiting_payment_review' WHERE id=rid;
 UPDATE public.direct_order_quotes SET status='locked' WHERE id=(quote->>'id')::uuid;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path,metadata)
 VALUES(rid,shop,'customer','payment_proof','Fixture proof',shop::text||'/'||rid::text||'/'||gen_random_uuid()::text||'.jpg',
  jsonb_build_object('quote_id',quote->>'id','quote_version','1')) RETURNING id INTO proof;
 PERFORM public.direct_order_record_receipt(shop,rid,(quote->>'id')::uuid,proof,36720,'Fixture-'||rid::text);
 PERFORM public.direct_order_record_receipt(shop,rid,(quote->>'id')::uuid,proof,36720,'Fixture-'||rid::text);
 ASSERT (SELECT current_stock=9928 FROM public.inventory_items WHERE id=ingredient),'direct option stock wrong/repeated';
 ASSERT (SELECT count(*)=2 FROM public.order_items oi JOIN public.direct_order_request_items ri ON oi.id=ri.id
  WHERE ri.request_id=rid AND oi.menu_option_snapshot=ri.menu_option_snapshot AND oi.unit_price=ri.unit_price),'approval option snapshot changed';
 ASSERT (SELECT count(*)=2 FROM public.direct_delivery_fulfillment_ticket_items ti JOIN public.direct_order_request_items ri ON ti.id=ri.id
  WHERE ri.request_id=rid AND ti.display_name_ko=ri.name_ko),'fulfillment option label lost';
 RAISE NOTICE 'REGISTERED_CHOICES_DIRECT=PASS';

 -- Two instances of the same combo must not multiply their fixed components.
 INSERT INTO public.menu_items(restaurant_id,name,name_ko,name_vi,name_en,price,invoice_sale_unit,is_visible_public,is_combo)
 VALUES(shop,'Combo choice','선택 세트','Combo tùy chọn','Combo choice',20000,'Phần',true,true) RETURNING id INTO combo;
 INSERT INTO public.menu_combo_components(restaurant_id,combo_menu_item_id,component_menu_item_id,quantity) VALUES(shop,combo,m.id,1);
 m:=public.admin_apply_menu_choices(combo,def);
 mild:=choice_test.key(m.menu_option_key,ARRAY['mild','less']);hot:=choice_test.key(m.menu_option_key,ARRAY['hot','normal']);
 payload:=jsonb_set(payload,'{items}',jsonb_build_array(jsonb_build_object('menu_item_id',m.id,'menu_option_key',mild,'quantity',1),jsonb_build_object('menu_item_id',m.id,'menu_option_key',hot,'quantity',2)));
 rid:=(public.direct_order_public_submit_v3(sid,secret,gen_random_uuid(),payload)->>'request_id')::uuid;
 ASSERT (SELECT count(*)=2 AND bool_and(jsonb_array_length(combo_components)=1) AND bool_and((combo_components->0->>'quantity')::int=1) FROM public.direct_order_request_items WHERE request_id=rid),'combo components multiplied by menu join';
 result:=public.direct_order_public_status_v11(sid,secret,rid);
 ASSERT jsonb_array_length(result->'items')=2 AND jsonb_array_length(result->'items'->0->'combo_components')=1,'public combo lines multiplied';
 quote:=public.direct_order_staff_quote_with_payment_mode(shop,rid,0,NULL,'customer_direct');
 ASSERT (quote->>'final_total')::numeric=69120,'combo choice quote wrong';
 UPDATE public.direct_order_requests SET state='awaiting_payment_review' WHERE id=rid;
 UPDATE public.direct_order_quotes SET status='locked' WHERE id=(quote->>'id')::uuid;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path,metadata)
 VALUES(rid,shop,'customer','payment_proof','Fixture proof',shop::text||'/'||rid::text||'/'||gen_random_uuid()::text||'.jpg',
  jsonb_build_object('quote_id',quote->>'id','quote_version','1')) RETURNING id INTO proof;
 PERFORM public.direct_order_record_receipt(shop,rid,(quote->>'id')::uuid,proof,69120,'Fixture-'||rid::text);
 PERFORM public.direct_order_record_receipt(shop,rid,(quote->>'id')::uuid,proof,69120,'Fixture-'||rid::text);
 ASSERT (SELECT current_stock=9892 FROM public.inventory_items WHERE id=ingredient),'combo choices consumed base/extra more than once';
 RAISE NOTICE 'REGISTERED_CHOICES_COMBO=PASS';
 UPDATE public.menu_items SET price=price+100 WHERE id=m.id;
 BEGIN PERFORM public.validate_menu_option_batch(shop,payload->'items','direct'); RAISE EXCEPTION 'STALE_CHOICE_ACCEPTED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'DIRECT_ORDER_MENU_CHANGED' THEN RAISE; END IF; END;
 ASSERT (SELECT bool_and(unit_price IN(20000,22000)) FROM public.direct_order_request_items WHERE request_id=rid),'historical price mutated';

END $$;
ROLLBACK;
