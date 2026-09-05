DO $test$
DECLARE
 scenario record;
 brand uuid; store uuid; ord uuid; food uuid; alcohol uuid; item uuid; disc uuid;
 paid payments; snapshot jsonb; result jsonb; actual_discount numeric; before_gross numeric;
BEGIN
 INSERT INTO brands DEFAULT VALUES RETURNING id INTO brand;
 INSERT INTO restaurants(brand_id) VALUES(brand) RETURNING id INTO store;
 INSERT INTO menu_items(vat_category) VALUES('food') RETURNING id INTO food;
 INSERT INTO menu_items(vat_category) VALUES('alcohol') RETURNING id INTO alcohol;
 FOR scenario IN SELECT * FROM (VALUES
   ('example_322600','exclusive',295000::numeric,0::numeric,NULL::text,0::numeric,false,322920::numeric),
   ('example_239440','exclusive',218000,0,NULL,0,false,239760),
   ('amount_discount','exclusive',100000,50000,'amount',10000,false,157320),
   ('percent_discount','exclusive',100000,50000,'percent',20,false,134720),
   ('targeted_food','exclusive',100000,50000,'percent',20,true,145720),
   ('full_food_discount','exclusive',100000,50000,'percent',100,true,59320),
   ('all_free_food','exclusive',100000,0,'percent',100,false,4320),
   ('inclusive','inclusive',108000,55000,'percent',20,true,145400)
 ) AS cases(name,pricing,food_price,alcohol_price,mode,value,scoped,total) LOOP
   UPDATE restaurants SET vat_pricing_mode=scenario.pricing WHERE id=store;
   INSERT INTO orders(restaurant_id) VALUES(store) RETURNING id INTO ord;
   INSERT INTO order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,display_name)
     VALUES(store,ord,food,scenario.food_price,1,'Food') RETURNING id INTO item;
   IF scenario.alcohol_price>0 THEN
     INSERT INTO order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,display_name)
       VALUES(store,ord,alcohol,scenario.alcohol_price,1,'Alcohol');
   END IF;
   -- The free service item from the 239440 incident stays excluded.
   INSERT INTO order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,display_name,is_service_item)
     VALUES(store,ord,food,59000,1,'Complimentary',true);
   result := set_order_wet_tissue_quantity(ord,store,2);
   IF (result->>'total_amount')::numeric <> (CASE WHEN scenario.pricing='inclusive' THEN 4000 ELSE 4320 END) THEN
     RAISE EXCEPTION 'wet tissue total incorrect: %',scenario.name;
   END IF;
   IF scenario.mode IS NOT NULL THEN
     INSERT INTO order_discounts(order_id,restaurant_id,discount_mode,discount_value,discount_amount,approved_via)
       VALUES(ord,store,scenario.mode,scenario.value,
         CASE WHEN scenario.scoped THEN 108000*scenario.value/100 ELSE 0 END,
         CASE WHEN scenario.scoped THEN 'scheduled_promotion' ELSE 'manager_pin' END) RETURNING id INTO disc;
     IF scenario.scoped THEN
       INSERT INTO order_discount_lines VALUES(disc,item,108000*scenario.value/100);
     END IF;
   END IF;
   paid := process_payment(ord,store,scenario.total,'CASH');
   IF (SELECT status FROM orders WHERE id=ord)<>'completed' THEN RAISE EXCEPTION 'not completed: %',scenario.name; END IF;
   IF EXISTS(SELECT 1 FROM order_items WHERE order_id=ord AND (abs(total_amount_ex_tax*vat_rate/100-vat_amount)>.02 OR total_amount_ex_tax+vat_amount<>paying_amount_inc_tax)) THEN
     RAISE EXCEPTION 'source arithmetic: %',scenario.name;
   END IF;
   IF (SELECT sum(paying_amount_inc_tax) FROM order_items WHERE order_id=ord)<>scenario.total THEN RAISE EXCEPTION 'source total: %',scenario.name; END IF;
   SELECT lines INTO STRICT snapshot FROM captured_invoice WHERE order_id=ord;
   IF EXISTS(SELECT 1 FROM jsonb_array_elements(snapshot) l JOIN order_items i ON i.id=(l->>'id')::uuid
      WHERE (l->>'vat_amount')::numeric<>i.vat_amount OR (l->>'total_amount_ex_tax')::numeric<>i.total_amount_ex_tax OR (l->>'paying_amount_inc_tax')::numeric<>i.paying_amount_inc_tax) THEN
     RAISE EXCEPTION 'invoice captured BEFORE final discount allocation: %',scenario.name;
   END IF;
   IF scenario.scoped AND (SELECT paying_amount_inc_tax FROM order_items WHERE id=item) <> 108000*(100-scenario.value)/100 THEN
     RAISE EXCEPTION 'targeted discount misallocated: %',scenario.name;
   END IF;
   RAISE NOTICE 'PASS: %',scenario.name;
 END LOOP;
 -- Rejected invalid allocation cannot leave a payment or invoice behind.
 INSERT INTO orders(restaurant_id) VALUES(store) RETURNING id INTO ord;
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,display_name)
   VALUES(store,ord,food,108000,1,'Food') RETURNING id INTO item;
 INSERT INTO order_discounts(order_id,restaurant_id,discount_mode,discount_value,discount_amount,approved_via)
   VALUES(ord,store,'amount',1000,1000,'scheduled_promotion') RETURNING id INTO disc;
 INSERT INTO order_discount_lines VALUES(disc,gen_random_uuid(),1000);
 BEGIN
   PERFORM process_payment(ord,store,107000,'CASH');
   RAISE EXCEPTION 'accepted an allocation to another order';
 EXCEPTION WHEN raise_exception THEN
   IF SQLERRM <> 'PROMOTION_ALLOCATION_MISMATCH' THEN RAISE; END IF;
 END;
 IF EXISTS(SELECT 1 FROM payments WHERE order_id=ord) OR EXISTS(SELECT 1 FROM captured_invoice WHERE order_id=ord) THEN RAISE EXCEPTION 'failed payment leaked writes'; END IF;
 RAISE NOTICE 'PASS: invalid allocation rolls back';
END $test$;
