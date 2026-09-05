CREATE TABLE legacy_cases(label text,order_id uuid);
DO $$
DECLARE store uuid; ord uuid; label text;
BEGIN
 INSERT INTO restaurants DEFAULT VALUES RETURNING id INTO store;
 FOREACH label IN ARRAY ARRAY['completed','partial','unpaid'] LOOP
   INSERT INTO orders(restaurant_id,status) VALUES(store,CASE WHEN label='completed' THEN 'completed' ELSE 'serving' END) RETURNING id INTO ord;
   INSERT INTO legacy_cases VALUES(label,ord);
   INSERT INTO order_items(restaurant_id,order_id,item_type,unit_price,quantity,status,vat_rate,vat_amount,total_amount_ex_tax,paying_amount_inc_tax)
     VALUES(store,ord,'wet_tissue_charge',2000,2,'ready',0,0,4000,4000);
   IF label<>'unpaid' THEN
     INSERT INTO payments(order_id,restaurant_id,amount,amount_portion,is_revenue) VALUES(ord,store,2000,2000,true);
   END IF;
 END LOOP;
END $$;
