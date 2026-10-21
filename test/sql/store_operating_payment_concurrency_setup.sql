BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
CREATE TABLE operating_test.concurrent_payments(order_id uuid PRIMARY KEY,store_id uuid);
CREATE TABLE operating_test.concurrent_stock(id uuid PRIMARY KEY,expected numeric);
DO $$ DECLARE shop uuid:='8bc9eef5-dcd5-46b1-b931-23f77132322c'; menu uuid; stock uuid; other_stock uuid;
BEGIN
 PERFORM public.approve_invoice_mapping_policy(shop,'91000000-0000-4000-8000-000000000004',
  'payment-race-fixture','{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','Isolated payment concurrency');
 UPDATE brands SET service_charge_enabled=false WHERE id='91000000-0000-4000-8000-000000000003';
 UPDATE restaurants SET vat_pricing_mode='exclusive' WHERE id=shop;
 INSERT INTO menu_items(restaurant_id,name,name_vi,price,invoice_sale_unit)
 VALUES(shop,'Payment race fixture','Món thử đồng thời',10000,'Phần') RETURNING id INTO menu;
 INSERT INTO inventory_items(restaurant_id,name,unit,current_stock) VALUES(shop,'Race ingredient 1','g',1000) RETURNING id INTO stock;
 INSERT INTO inventory_items(restaurant_id,name,unit,current_stock) VALUES(shop,'Race ingredient 2','g',1000) RETURNING id INTO other_stock;
 INSERT INTO menu_recipes(restaurant_id,menu_item_id,ingredient_id,quantity_g) VALUES(shop,menu,stock,10),(shop,menu,other_stock,3);
 INSERT INTO operating_test.concurrent_stock VALUES(stock,980),(other_stock,994);
 WITH made AS (INSERT INTO orders(restaurant_id,status) SELECT shop,'serving' FROM generate_series(1,2) RETURNING id)
 INSERT INTO operating_test.concurrent_payments SELECT id,shop FROM made;
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,item_type,label,display_name,unit_price,quantity,status)
 SELECT shop,order_id,menu,'menu_item','Payment race fixture','Payment race fixture',10000,1,'served'
 FROM operating_test.concurrent_payments;
END $$;
COMMIT;
