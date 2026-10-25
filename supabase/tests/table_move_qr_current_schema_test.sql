-- Run after store_operating_upgrade_setup.sql in an isolated current-schema DB.
-- No production data or external workers are used.
\set ON_ERROR_STOP on
BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
DO $$ DECLARE shop uuid:='273b057e-3b69-46e3-93c1-6194c2802849'; tab uuid; menu uuid; o public.orders; result jsonb; expected jsonb; actual jsonb; BEGIN
 PERFORM public.approve_invoice_mapping_policy(shop,'91000000-0000-4000-8000-000000000004','qr-balance-fixture','{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','isolated QR quote approval');
 INSERT INTO public.menu_items(restaurant_id,name,name_vi,invoice_sale_unit,price) VALUES(shop,'QR drink','Đồ uống','Phần',18000) RETURNING id INTO menu;
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(shop,'balance-smoke','2F') RETURNING id INTO tab;
 INSERT INTO public.table_qr_tokens(restaurant_id,table_id,token) VALUES(shop,tab,'isolated-current-schema-balance');
 o:=public.create_order(shop,tab,jsonb_build_array(jsonb_build_object('menu_item_id',menu,'quantity',3)));
 result:=public.qr_get_active_order('isolated-current-schema-balance');
 ASSERT (result->>'active')::boolean,result::text;
 ASSERT result->'payment_summary'->>'currency'='VND';
 ASSERT (result->'payment_summary'->>'remaining_due')::numeric=58320,result::text;
 ASSERT jsonb_array_length(result->'items')=1;
 ASSERT result->'items'->0->>'order_item_id' IS NOT NULL,'stable line identity missing';
 -- The batched base preserves names, quantities, modes and delivery parts.
 expected:=public.fixture_qr_base_before('isolated-current-schema-balance');
 actual:=public.qr_get_active_order_pre_takeout('isolated-current-schema-balance');
 actual:=jsonb_set(actual,'{items}',(SELECT jsonb_agg(i-'order_item_id' ORDER BY n) FROM jsonb_array_elements(actual->'items') WITH ORDINALITY a(i,n)));
 ASSERT actual=expected,'batched QR base changed the delivery contract';
 actual:=public.emergency_enrich_qr_unserved_items(o.id,result->'items');
 expected:=public.fixture_qr_enrich_before(o.id,result->'items');
 ASSERT actual=expected,'batched QR progress changed ordered lines';
END $$;
SELECT 'CURRENT_SCHEMA_QR_BALANCE=PASS base_parity=PASS progress_parity=PASS';
ROLLBACK;
