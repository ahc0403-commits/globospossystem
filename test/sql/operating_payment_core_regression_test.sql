-- Financial-core CI fixture. Real full-schema permissions, MISA and KDS are
-- separately exercised by test_store_operating_upgrade.sh.
BEGIN;
CREATE FUNCTION operating_test.outcome(oid uuid) RETURNS jsonb LANGUAGE sql AS $$
 SELECT jsonb_build_object(
  'status',(SELECT status FROM orders WHERE id=oid),
  'lines',(SELECT jsonb_agg(to_jsonb(i)-'id'-'created_at' ORDER BY item_type,label,unit_price,quantity)
    FROM order_items i WHERE order_id=oid),
  'payments',(SELECT jsonb_agg(jsonb_build_array(method,amount,is_revenue) ORDER BY method) FROM payments WHERE order_id=oid),
  'discount',(SELECT jsonb_agg(jsonb_build_array(discount_mode,discount_value,discount_amount,status)) FROM order_discounts WHERE order_id=oid),
  'stock',(SELECT jsonb_agg(jsonb_build_array(ingredient_id,reference_id,quantity_g) ORDER BY ingredient_id,reference_id)
    FROM inventory_transactions WHERE reference_id IN(SELECT id FROM order_items WHERE order_id=oid)),
  'captured_invoice',(SELECT jsonb_agg(lines ORDER BY order_id) FROM
    (SELECT order_id,jsonb_agg(e-'id'-'created_at' ORDER BY e->>'item_type',e->>'label',e->>'unit_price') lines
      FROM captured_invoice CROSS JOIN LATERAL jsonb_array_elements(lines)e WHERE order_id=oid GROUP BY order_id)x)
 );
$$;
CREATE FUNCTION operating_test.pay(oid uuid,shop uuid,legacy boolean,zero_total boolean) RETURNS void LANGUAGE plpgsql AS $$
DECLARE amount numeric:=CASE WHEN zero_total THEN 0 ELSE 1 END;
BEGIN
 IF legacy THEN PERFORM operating_test.payment_wrapper_before_operating(oid,shop,amount,'CASH');
 ELSE PERFORM public.process_payment_before_promotion_read_split(oid,shop,amount,'CASH'); END IF;
 IF (SELECT status<>'completed' FROM orders WHERE id=oid) THEN
  SELECT sum(paying_amount_inc_tax)-amount INTO amount FROM order_items WHERE order_id=oid AND status<>'cancelled';
  IF legacy THEN PERFORM operating_test.payment_wrapper_before_operating(oid,shop,amount,'BANKTRANSFER');
  ELSE PERFORM public.process_payment_before_promotion_read_split(oid,shop,amount,'BANKTRANSFER'); END IF;
 END IF;
END $$;
DO $$ DECLARE brand uuid:=gen_random_uuid(); shop uuid:=gen_random_uuid(); food uuid:=gen_random_uuid(); drink uuid:=gen_random_uuid();
 stock uuid:=gen_random_uuid(); stock2 uuid:=gen_random_uuid(); oid uuid; iid uuid; discount uuid;
 scenario record; old_result jsonb; new_result jsonb; count_cases int:=0;
BEGIN
 INSERT INTO brands(id) VALUES(brand);
 INSERT INTO restaurants(id,brand_id) VALUES(shop,brand);
 INSERT INTO menu_items(id,vat_category,effective_vat_rate) VALUES(food,'food',8),(drink,'alcohol',10);
 INSERT INTO inventory_items(id,restaurant_id,current_stock) VALUES(stock,shop,100000),(stock2,shop,100000);
 INSERT INTO menu_recipes VALUES(food,shop,stock,1.234),(drink,shop,stock,2.345);
 FOR scenario IN SELECT mode,service,discount_mode FROM unnest(ARRAY['exclusive','inclusive']) mode
 CROSS JOIN unnest(ARRAY[false,true]) service CROSS JOIN unnest(ARRAY['none','percent','amount','targeted','full']) discount_mode LOOP
  UPDATE restaurants SET vat_pricing_mode=scenario.mode WHERE id=shop;
  UPDATE brands SET service_charge_enabled=scenario.service,service_charge_rate=3.17 WHERE id=brand;
  INSERT INTO orders(restaurant_id) VALUES(shop) RETURNING id INTO oid;
  INSERT INTO order_items(restaurant_id,order_id,menu_item_id,label,display_name,unit_price,quantity)
  VALUES(shop,oid,food,'Food','Food',101.01,3) RETURNING id INTO iid;
  INSERT INTO order_items(restaurant_id,order_id,menu_item_id,label,display_name,unit_price,quantity,is_service_item)
  VALUES(shop,oid,drink,'Alcohol','Alcohol',77.77,2,false),
   (shop,oid,food,'Extra','Extra',33.33,1,false),(shop,oid,food,'Complimentary','Complimentary',23.45,1,true);
  INSERT INTO order_items(restaurant_id,order_id,menu_item_id,label,display_name,unit_price,quantity,status,cancelled_consumed_quantity)
  VALUES(shop,oid,food,'Cancelled','Cancelled',33.33,2,'cancelled',1);
  IF scenario.discount_mode<>'none' THEN
   INSERT INTO order_discounts(restaurant_id,order_id,discount_mode,discount_value,discount_amount,approved_via)
   VALUES(shop,oid,CASE WHEN scenario.discount_mode IN ('percent','full') THEN 'percent' ELSE 'amount' END,
    CASE WHEN scenario.discount_mode='full' THEN 100 WHEN scenario.discount_mode='percent' THEN 13.37 ELSE 5.01 END,
    CASE WHEN scenario.discount_mode='targeted' THEN 5.01 ELSE 0 END,
    CASE WHEN scenario.discount_mode='targeted' THEN 'scheduled_promotion' ELSE 'manager_pin' END) RETURNING id INTO discount;
   IF scenario.discount_mode='targeted' THEN INSERT INTO order_discount_lines VALUES(discount,iid,5.01); END IF;
  END IF;
  BEGIN
   PERFORM operating_test.pay(oid,shop,true,scenario.discount_mode='full' AND NOT scenario.service);
   old_result:=operating_test.outcome(oid);
   RAISE EXCEPTION USING ERRCODE='P1999',MESSAGE='rollback baseline';
  EXCEPTION WHEN SQLSTATE 'P1999' THEN NULL; END;
  PERFORM operating_test.pay(oid,shop,false,scenario.discount_mode='full' AND NOT scenario.service);
  new_result:=operating_test.outcome(oid);
  ASSERT old_result=new_result,format('core parity failed: %s %s %s',scenario.mode,scenario.service,scenario.discount_mode);
  count_cases:=count_cases+1;
 END LOOP;
 ASSERT count_cases=20;
 -- Independent fixed expectations exercise quantity, scale and retries.
 UPDATE brands SET service_charge_enabled=false WHERE id=brand;
 UPDATE restaurants SET vat_pricing_mode='exclusive' WHERE id=shop;
 UPDATE inventory_items SET current_stock=100000 WHERE id IN(stock,stock2);
 DELETE FROM menu_recipes WHERE restaurant_id=shop;
 INSERT INTO menu_recipes VALUES(food,shop,stock,10),(food,shop,stock2,2);
 INSERT INTO orders(restaurant_id) VALUES(shop) RETURNING id INTO oid;
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,label,unit_price,quantity,cancelled_consumed_quantity)
 SELECT shop,oid,food,'Bulk',10000,3,1 FROM generate_series(1,500);
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,label,unit_price,quantity,status,cancelled_consumed_quantity)
 VALUES(shop,oid,food,'Cancelled',10000,2,'cancelled',2);
 PERFORM public.process_payment_without_scoped_promotions(oid,shop,8000000,'CASH');
 ASSERT (SELECT current_stock=100000 FROM inventory_items WHERE id=stock);
 PERFORM public.process_payment_without_scoped_promotions(oid,shop,8200000,'BANKTRANSFER');
 ASSERT (SELECT current_stock=79980 FROM inventory_items WHERE id=stock);
 ASSERT (SELECT current_stock=95996 FROM inventory_items WHERE id=stock2);
 ASSERT (SELECT count(*)=1002 AND sum(quantity_g)=-24024 FROM inventory_transactions
  WHERE reference_id IN(SELECT id FROM order_items WHERE order_id=oid));
 ASSERT (SELECT count(*)=1 FROM captured_invoice WHERE order_id=oid);
 BEGIN PERFORM public.process_payment_without_scoped_promotions(oid,shop,1,'CASH');
  RAISE EXCEPTION 'duplicate payment accepted';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'ORDER_NOT_PAYABLE' THEN RAISE; END IF; END;
 ASSERT (SELECT count(*)=2 AND sum(amount)=16200000 FROM payments WHERE order_id=oid);
 RAISE NOTICE 'OPERATING_PAYMENT_CORE_CI=PASS 20 differential cases, 500 lines, consumed cancellations, 1002 journals, invoice capture, retry';
END $$;
ROLLBACK;
