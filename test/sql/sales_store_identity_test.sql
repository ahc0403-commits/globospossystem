BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
DO $$ DECLARE
 shop uuid:='8bc9eef5-dcd5-46b1-b931-23f77132322c'; entity uuid:='91000000-0000-4000-8000-000000000004';
 original_name text; menu uuid; ord uuid; page jsonb; receipt jsonb; day date:=(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
BEGIN
 SELECT name INTO original_name FROM restaurants WHERE id=shop;
 UPDATE brands SET service_charge_enabled=false WHERE id='91000000-0000-4000-8000-000000000003';
 PERFORM public.approve_invoice_mapping_policy(shop,entity,'identity-fixture','{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','isolated fixture');
 INSERT INTO menu_items(restaurant_id,name,name_vi,invoice_sale_unit,price) VALUES(shop,'Identity meal','Món thử','Phần',10000) RETURNING id INTO menu;
 INSERT INTO orders(restaurant_id,status) VALUES(shop,'serving') RETURNING id INTO ord;
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,display_name,quantity,unit_price,status) VALUES(shop,ord,menu,'Identity meal',1,10000,'served');
 PERFORM public.process_payment(ord,shop,10800,'CASH');
 ASSERT (SELECT store_name=original_name AND restaurant_id=shop FROM store_sale_identities WHERE order_id=ord);
 UPDATE restaurants SET name='Renamed operating branch' WHERE id=shop;
 page:=public.get_pos_daily_sales_export_page(day,entity,'restaurant_pos');
 SELECT r INTO receipt FROM jsonb_array_elements(page->'rows')r WHERE r->>'receipt_id'=ord::text;
 ASSERT receipt->>'store_name'=original_name AND receipt->>'store_name_origin'='order_snapshot',receipt::text;
 ASSERT receipt->>'store_id'=shop::text AND (receipt->>'gross_sales')::numeric=10800;
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(page->'rows')r WHERE r->>'store_name_origin'='current_registry'),'legacy names falsely represented as snapshots';
 BEGIN UPDATE store_sale_identities SET store_name='Rewritten' WHERE order_id=ord; RAISE EXCEPTION 'sale identity was mutable'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='OPERATING_PROFILE_IMMUTABLE',SQLERRM; END;
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000006',true);
 BEGIN PERFORM public.get_pos_daily_sales_export_page(day,entity,'restaurant_pos'); RAISE EXCEPTION 'store export accessible to kitchen'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='SUPER_ADMIN_ONLY',SQLERRM; END;
END $$;
SELECT 'SALES_STORE_IDENTITY=PASS';
ROLLBACK;
