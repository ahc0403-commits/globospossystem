BEGIN;
SELECT set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
CREATE SCHEMA combo_test;
CREATE TABLE combo_test.scope(shop uuid,session_id uuid,secret text,request_id uuid,proof_id uuid);
INSERT INTO menu_categories(id,restaurant_id,name,name_ko,name_vi,name_en,sort_order,is_active,system_key) VALUES
 ('c4000000-0000-4000-8000-000000000001','d1000000-0000-4000-8000-000000000002','Combos','콤보','Combo','Combo',-100,true,'combo'),
 ('c4000000-0000-4000-8000-000000000002','d1000000-0000-4000-8000-000000000002','Drinks','음료','Đồ uống','Drinks',-99,true,'drink');
INSERT INTO menu_items(id,restaurant_id,category_id,name,name_ko,name_vi,name_en,price,sort_order,is_combo,combo_drink_choice_count,effective_vat_rate) VALUES
 ('c5000000-0000-4000-8000-000000000001','d1000000-0000-4000-8000-000000000002','c4000000-0000-4000-8000-000000000001','Combo two','콤보2','Combo hai','Combo two',100000,-100,true,2,8),
 ('c5000000-0000-4000-8000-000000000002','d1000000-0000-4000-8000-000000000002','c4000000-0000-4000-8000-000000000001','Fixed food','음식','Món cố định','Fixed food',60000,-99,false,0,8),
 ('c5000000-0000-4000-8000-000000000003','d1000000-0000-4000-8000-000000000002','c4000000-0000-4000-8000-000000000002','Drink 10','음료10','Đồ uống 10','Drink 10',20000,-98,false,0,10),
 ('c5000000-0000-4000-8000-000000000004','d1000000-0000-4000-8000-000000000002','c4000000-0000-4000-8000-000000000002','Drink 8','음료8','Đồ uống 8','Drink 8',20000,-97,false,0,8),
 ('c5000000-0000-4000-8000-000000000005','d1000000-0000-4000-8000-000000000002','c4000000-0000-4000-8000-000000000001','Combo one','콤보1','Combo một','Combo one',80000,-96,true,1,8);
INSERT INTO menu_combo_components(restaurant_id,combo_menu_item_id,component_menu_item_id,quantity) VALUES
 ('d1000000-0000-4000-8000-000000000002','c5000000-0000-4000-8000-000000000001','c5000000-0000-4000-8000-000000000002',1),
 ('d1000000-0000-4000-8000-000000000002','c5000000-0000-4000-8000-000000000005','c5000000-0000-4000-8000-000000000002',1);
INSERT INTO inventory_items(id,restaurant_id,current_stock) VALUES('c6000000-0000-4000-8000-000000000001','d1000000-0000-4000-8000-000000000002',1000);
INSERT INTO menu_recipes(menu_item_id,restaurant_id,ingredient_id,quantity_g) VALUES
 ('c5000000-0000-4000-8000-000000000001','d1000000-0000-4000-8000-000000000002','c6000000-0000-4000-8000-000000000001',999),
 ('c5000000-0000-4000-8000-000000000002','d1000000-0000-4000-8000-000000000002','c6000000-0000-4000-8000-000000000001',10),
 ('c5000000-0000-4000-8000-000000000003','d1000000-0000-4000-8000-000000000002','c6000000-0000-4000-8000-000000000001',2),
 ('c5000000-0000-4000-8000-000000000004','d1000000-0000-4000-8000-000000000002','c6000000-0000-4000-8000-000000000001',1);
DO $combo$
DECLARE shop uuid:='d1000000-0000-4000-8000-000000000002'; sid uuid; secret text:=md5(gen_random_uuid()::text)||md5(gen_random_uuid()::text); rid uuid; cid uuid:=gen_random_uuid();
 payload jsonb; v jsonb; q jsonb; doc jsonb; proof uuid; before_stock numeric; item public.direct_order_request_items%ROWTYPE; slug text; page jsonb; old_hash text;
BEGIN
 IF has_function_privilege('authenticated','public.direct_order_approve_photo_payment(uuid,uuid,numeric,uuid,uuid)','EXECUTE') THEN RAISE EXCEPTION 'LEGACY_APPROVAL_ENTRY_EXPOSED'; END IF;
 UPDATE users SET restaurant_id=shop,role='cashier' WHERE auth_id=auth.uid();
 UPDATE direct_order_storefronts SET is_paused=false,ordering_hours_enforced=false,minimum_order_amount=0 WHERE restaurant_id=shop RETURNING public_slug INTO slug;
 INSERT INTO direct_order_sessions(restaurant_id,secret_hash,locale) VALUES(shop,secret,'vi') RETURNING id INTO sid;
 page:=public.direct_order_public_storefront_v3(slug,NULL,NULL,2);
 IF jsonb_array_length(page->'items')<>2 OR page->'next_cursor'='null'::jsonb
 OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(page->'items')e WHERE e->>'id'='c5000000-0000-4000-8000-000000000001')
 OR jsonb_array_length(page->'combo_drink_options')<>2 THEN RAISE EXCEPTION 'COMBO_PAGE_MISSING'; END IF;
 v:=public.direct_order_public_storefront_v3(slug,(page->'next_cursor'->>'sort_order')::integer,(page->'next_cursor'->>'id')::uuid,2);
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(page->'items')a JOIN jsonb_array_elements(v->'items')b ON a->>'id'=b->>'id') THEN RAISE EXCEPTION 'MENU_CURSOR_DUPLICATED'; END IF;
 payload:=jsonb_build_object('locale','vi','fulfillment_type','delivery','diner_count',2,'utensils_requested',false,
 'address',jsonb_build_object('customer_name','Fixture only','customer_phone','0901234567','formatted_address','123 Fixture Street','detail_address','Door','address_source','manual'),
 'items',jsonb_build_array(jsonb_build_object('menu_item_id','c5000000-0000-4000-8000-000000000001','quantity',2,'combo_drink_choices',jsonb_build_array(
  'c5000000-0000-4000-8000-000000000003','c5000000-0000-4000-8000-000000000003','c5000000-0000-4000-8000-000000000004','c5000000-0000-4000-8000-000000000004'))));
 BEGIN PERFORM public.direct_order_public_submit_v3(sid,secret,gen_random_uuid(),jsonb_set(payload,'{items,0,combo_drink_choices}','[]')); RAISE EXCEPTION 'MISSING_DRINK_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_COMBO_UNAVAILABLE' THEN RAISE; END IF; END;
 BEGIN PERFORM public.direct_order_public_submit_v3(sid,secret,gen_random_uuid(),jsonb_set(payload,'{items,0,combo_drink_choices,0}','"bad"')); RAISE EXCEPTION 'MALFORMED_DRINK_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_COMBO_CHOICES_INVALID' THEN RAISE; END IF; END;
 v:=public.direct_order_public_submit_v3(sid,secret,cid,payload); rid:=(v->>'request_id')::uuid;
 IF public.direct_order_public_submit_v3(sid,secret,cid,payload)->>'request_id'<>rid::text OR (SELECT count(*) FROM direct_order_requests WHERE client_request_id=cid)<>1 THEN RAISE EXCEPTION 'COMBO_SUBMIT_DUPLICATE'; END IF;
 SELECT * INTO item FROM direct_order_request_items WHERE request_id=rid;
 IF jsonb_array_length(item.combo_components)<>3 OR jsonb_array_length(item.combo_drink_choices)<>4
 OR item.vat_profile_snapshot IS DISTINCT FROM public.menu_vat_profile(item.menu_item_id,shop,item.combo_components,item.quantity) THEN RAISE EXCEPTION 'COMBO_SNAPSHOT_OR_TAX_WRONG'; END IF;
 v:=public.direct_order_public_status_v11(sid,secret,rid);
 IF jsonb_array_length(v->'items'->0->'combo_components')<>3 THEN RAISE EXCEPTION 'CUSTOMER_COMPONENTS_MISSING'; END IF;
 v:=public.direct_order_staff_detail_v8(shop,rid);
 IF jsonb_array_length(v->'items'->0->'combo_components')<>3 THEN RAISE EXCEPTION 'STAFF_COMPONENTS_MISSING'; END IF;
 q:=public.direct_order_staff_quote_with_payment_mode(shop,rid,0,NULL,'customer_direct');
 IF (q->>'final_total')::numeric<>216800 THEN RAISE EXCEPTION 'COMBO_QUOTE_TAX_WRONG: %',q; END IF;
 doc:=public.direct_order_staff_payment_document(shop,rid,(q->>'id')::uuid,1);
 IF jsonb_array_length(doc->'data'->'items'->0->'combo_components')<>3 THEN RAISE EXCEPTION 'COMBO_DOCUMENT_MISSING'; END IF;
 UPDATE direct_order_requests SET state='awaiting_payment_review' WHERE id=rid;
 UPDATE direct_order_quotes SET status='locked' WHERE id=(q->>'id')::uuid;
 INSERT INTO direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path,metadata)
 VALUES(rid,shop,'customer','payment_proof','Fixture proof',shop::text||'/'||rid::text||'/'||gen_random_uuid()::text||'.jpg',
 jsonb_build_object('quote_id',q->>'id','quote_version','1')) RETURNING id INTO proof;
 v:=public.direct_order_record_receipt(shop,rid,(q->>'id')::uuid,proof,216800,'Fixture-'||rid::text);
 IF (SELECT current_stock FROM inventory_items WHERE id='c6000000-0000-4000-8000-000000000001')<>974 THEN RAISE EXCEPTION 'COMBO_STOCK_WRONG'; END IF;
 IF (SELECT sum(quantity_g) FROM inventory_transactions WHERE reference_id IN(SELECT oi.id FROM order_items oi JOIN direct_order_financials f ON f.order_id=oi.order_id WHERE f.request_id=rid))<>-26
 OR (SELECT count(*) FROM payments WHERE order_id=(SELECT order_id FROM direct_order_financials WHERE request_id=rid))<>1
 OR EXISTS(SELECT 1 FROM direct_order_financials WHERE request_id=rid AND (final_total<>216800 OR delivery_fee_item_id IS NOT NULL)) THEN RAISE EXCEPTION 'COMBO_FINANCE_OR_LEDGER_WRONG'; END IF;
 PERFORM public.direct_order_record_receipt(shop,rid,(q->>'id')::uuid,proof,216800,'Fixture-'||rid::text);
 IF (SELECT current_stock FROM inventory_items WHERE id='c6000000-0000-4000-8000-000000000001')<>974 THEN RAISE EXCEPTION 'COMBO_RETRY_DEDUCTED_TWICE'; END IF;
 IF EXISTS(SELECT 1 FROM order_items oi JOIN direct_order_financials f ON f.order_id=oi.order_id WHERE f.request_id=rid AND oi.item_type='menu_item' AND (jsonb_array_length(oi.combo_components)<>3 OR oi.vat_profile_snapshot<>item.vat_profile_snapshot)) THEN RAISE EXCEPTION 'COMBO_ORDER_SNAPSHOT_MISSING'; END IF;
 INSERT INTO combo_test.scope VALUES(shop,sid,secret,rid,proof);
 UPDATE menu_items SET is_available=false WHERE id='c5000000-0000-4000-8000-000000000003';
 BEGIN PERFORM public.direct_order_public_submit_v3(sid,secret,gen_random_uuid(),payload); RAISE EXCEPTION 'SOLD_OUT_DRINK_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_COMBO_UNAVAILABLE' THEN RAISE; END IF; END;
 UPDATE menu_items SET is_available=true WHERE id='c5000000-0000-4000-8000-000000000003';
 RAISE NOTICE 'COMBO_ORDERING=PASS cursor, validation, immutable choice/tax snapshot, quote, customer/staff/document, real payment, component stock, approval retry';
END $combo$;

CREATE FUNCTION combo_test.rounding_case(mode text,service boolean) RETURNS void LANGUAGE plpgsql AS $$
DECLARE shop uuid:='d1000000-0000-4000-8000-000000000002';sid uuid;hash text:=md5(gen_random_uuid()::text)||md5(gen_random_uuid()::text);rid uuid;q jsonb;proof uuid;payload jsonb;old_stock numeric;
BEGIN
 UPDATE restaurants SET vat_pricing_mode=mode WHERE id=shop;
 UPDATE brands SET service_charge_enabled=service,service_charge_rate=3.17 WHERE id=(SELECT brand_id FROM restaurants WHERE id=shop);
 UPDATE menu_items SET price=99001 WHERE id='c5000000-0000-4000-8000-000000000005';
 INSERT INTO direct_order_sessions(restaurant_id,secret_hash,locale) VALUES(shop,hash,'vi') RETURNING id INTO sid;
 payload:=jsonb_build_object('locale','vi','fulfillment_type','delivery','diner_count',1,
 'address',jsonb_build_object('customer_name','Fixture only','customer_phone','0901234567','formatted_address','123 Fixture Street','detail_address','Door','address_source','manual'),
 'items',jsonb_build_array(jsonb_build_object('menu_item_id','c5000000-0000-4000-8000-000000000005','quantity',1,'combo_drink_choices',jsonb_build_array('c5000000-0000-4000-8000-000000000003'))));
 rid:=(public.direct_order_public_submit_v3(sid,hash,gen_random_uuid(),payload)->>'request_id')::uuid;
 q:=public.direct_order_staff_quote_with_payment_mode(shop,rid,0,NULL,'customer_direct');
 IF (q->>'final_total')::numeric<>trunc((q->>'final_total')::numeric) THEN RAISE EXCEPTION 'COMBO_FRACTIONAL_BANK_AMOUNT:%',q; END IF;
 UPDATE direct_order_requests SET state='awaiting_payment_review' WHERE id=rid;
 UPDATE direct_order_quotes SET status='locked' WHERE id=(q->>'id')::uuid;
 INSERT INTO direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path,metadata)
 VALUES(rid,shop,'customer','payment_proof','Fixture proof',shop::text||'/'||rid::text||'/'||gen_random_uuid()::text||'.jpg',
 jsonb_build_object('quote_id',q->>'id','quote_version','1')) RETURNING id INTO proof;
 SELECT current_stock INTO old_stock FROM inventory_items WHERE id='c6000000-0000-4000-8000-000000000001';
 PERFORM public.direct_order_record_receipt(shop,rid,(q->>'id')::uuid,proof,(q->>'final_total')::numeric,'Fixture-'||rid::text);
 IF (SELECT current_stock FROM inventory_items WHERE id='c6000000-0000-4000-8000-000000000001')<>old_stock-12 THEN RAISE EXCEPTION 'VND_STOCK_CHANGED'; END IF;
 IF (SELECT final_total FROM direct_order_financials WHERE request_id=rid)<>(q->>'final_total')::numeric
 OR (SELECT sum(oi.paying_amount_inc_tax) FROM order_items oi JOIN direct_order_financials f ON f.order_id=oi.order_id WHERE f.request_id=rid AND oi.status<>'cancelled')<>(q->>'final_total')::numeric
 THEN RAISE EXCEPTION 'VND_QUOTE_PAYMENT_INVOICE_MISMATCH'; END IF;
 PERFORM public.direct_order_record_receipt(shop,rid,(q->>'id')::uuid,proof,(q->>'final_total')::numeric,'Fixture-'||rid::text);
 RAISE NOTICE 'COMBO_VND_ROUNDING=PASS mode=% service=% total=%',mode,service,q->>'final_total';
END $$;
SELECT combo_test.rounding_case('exclusive',false);
SELECT combo_test.rounding_case('exclusive',true);
SELECT combo_test.rounding_case('inclusive',false);
SELECT combo_test.rounding_case('inclusive',true);
UPDATE restaurants SET vat_pricing_mode='exclusive' WHERE id='d1000000-0000-4000-8000-000000000002';
UPDATE brands SET service_charge_enabled=false WHERE id=(SELECT brand_id FROM restaurants WHERE id='d1000000-0000-4000-8000-000000000002');
COMMIT;
