DO $$
DECLARE brand uuid; store uuid; ord uuid; food uuid; alcohol uuid; item uuid; disc uuid; snapshot_supply numeric;
BEGIN
 INSERT INTO brands DEFAULT VALUES RETURNING id INTO brand;
 INSERT INTO restaurants(brand_id) VALUES(brand) RETURNING id INTO store;
 INSERT INTO menu_items(vat_category) VALUES('food') RETURNING id INTO food;
 INSERT INTO menu_items(vat_category) VALUES('alcohol') RETURNING id INTO alcohol;
 INSERT INTO orders(restaurant_id) VALUES(store) RETURNING id INTO ord;
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,display_name)
   VALUES(store,ord,food,100000,1,'Food') RETURNING id INTO item;
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,display_name)
   VALUES(store,ord,alcohol,50000,1,'Alcohol');
 INSERT INTO order_discounts(order_id,restaurant_id,discount_mode,discount_value,discount_amount,approved_via)
   VALUES(ord,store,'percent',20,21600,'scheduled_promotion') RETURNING id INTO disc;
 INSERT INTO order_discount_lines VALUES(disc,item,21600);
 PERFORM process_payment(ord,store,141400,'CASH');
 SELECT (l->>'total_amount_ex_tax')::numeric INTO snapshot_supply
 FROM captured_invoice c CROSS JOIN LATERAL jsonb_array_elements(c.lines) l
 WHERE c.order_id=ord AND (l->>'id')::uuid=item;
 IF snapshot_supply <> 80000 THEN
   RAISE EXCEPTION 'SCOPED_SNAPSHOT_RACE: expected food supply 80000, captured %',snapshot_supply;
 END IF;
 RAISE NOTICE 'PASS: targeted promotion snapshot records final VAT base';
END $$;
