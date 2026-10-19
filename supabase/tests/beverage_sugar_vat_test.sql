BEGIN;
DO $$
DECLARE a jsonb; b jsonb;
BEGIN
 a:=public.calculate_item_vat('[{"rate":8,"weight":100000},{"rate":10,"weight":100000}]',200000,'exclusive');
 IF (a->>'total')::numeric<>218000 OR (a->>'vat')::numeric<>18000 THEN RAISE EXCEPTION 'Mixed VAT: %',a; END IF;
 b:=public.calculate_item_vat('[{"rate":8,"weight":100000},{"rate":10,"weight":100000}]',200000,'exclusive',21800);
 IF (b->>'total')::numeric<>196200 OR (b->>'vat')::numeric<>16200 THEN RAISE EXCEPTION 'Discount VAT: %',b; END IF;
 a:=public.calculate_item_vat('[{"rate":8,"weight":108000},{"rate":10,"weight":110000}]',218000,'inclusive');
 IF (a->>'supply')::numeric<>200000 OR (a->>'vat')::numeric<>18000 THEN RAISE EXCEPTION 'Inclusive VAT: %',a; END IF;
END $$;


DO $test$
DECLARE store uuid; brand uuid; category uuid; food public.menu_items; coke public.menu_items;
 combo public.menu_items; ord uuid; line uuid; discount_id uuid; paid public.payments;
 captured jsonb; x record; amount numeric; vat numeric; request_id uuid:=gen_random_uuid();
BEGIN
 INSERT INTO public.brands DEFAULT VALUES RETURNING id INTO brand;
 INSERT INTO public.restaurants(brand_id) VALUES(brand) RETURNING id INTO store;
 INSERT INTO public.menu_categories(restaurant_id,name) VALUES(store,'Drinks') RETURNING id INTO category;
 food:=public.admin_create_menu_item_with_tax(store,category,'음식','Mon an','Food',NULL,100000,
   '{"beverage_sugar_tax_class":"not_applicable"}');
 coke:=public.admin_create_menu_item_with_tax(store,category,'콜라','Coca','Coca-Cola',NULL,100000,
   '{"beverage_sugar_tax_class":"gt_5","tax_basis_note":"User confirmed SKU"}');
 IF coke.effective_vat_rate<>10 OR coke.vat_category<>'food' OR coke.sugar_g_per_100ml IS NOT NULL THEN
   RAISE EXCEPTION 'SKU must use 10%% without inventing grams or changing business category'; END IF;
 FOR x IN SELECT * FROM (VALUES(0::numeric,'lte_5',8),(4.99,'lte_5',8),(5.00,'lte_5',8),(5.01,'gt_5',10)) t(grams,class,rate) LOOP
   coke:=public.admin_set_menu_beverage_tax(coke.id,jsonb_build_object('beverage_sugar_tax_class',x.class,'sugar_g_per_100ml',x.grams));
   IF coke.effective_vat_rate<>x.rate THEN RAISE EXCEPTION 'Boundary %',x.grams; END IF;
 END LOOP;
 BEGIN
   PERFORM public.admin_update_menu_item_with_tax(coke.id,'changed','changed','changed',NULL,1,
     '{"beverage_sugar_tax_class":"gt_5","sugar_g_per_100ml":5}');
   RAISE EXCEPTION 'Accepted inconsistent classification';
 EXCEPTION WHEN raise_exception THEN
   IF SQLERRM<>'MENU_TAX_INVALID' THEN RAISE; END IF;
 END;
 IF (SELECT price FROM menu_items WHERE id=coke.id)<>100000 THEN RAISE EXCEPTION 'Invalid tax left partial menu edit'; END IF;
 PERFORM set_config('beverage_test.deny_admin','true',true);
 BEGIN
   PERFORM public.admin_set_menu_beverage_tax(coke.id,'{"beverage_sugar_tax_class":"not_applicable"}');
   RAISE EXCEPTION 'Unauthorized edit accepted';
 EXCEPTION WHEN raise_exception THEN
   IF SQLERRM<>'ADMIN_MUTATION_FORBIDDEN' THEN RAISE; END IF;
 END;
 PERFORM set_config('beverage_test.deny_admin','false',true);
 -- Old Excel has no tax columns: changing the price must preserve classification.
 PERFORM public.admin_update_menu_workbook_i18n(store,'[]',jsonb_build_array(jsonb_build_object('item_id',coke.id,'price',100000)));
 IF (SELECT effective_vat_rate FROM menu_items WHERE id=coke.id)<>10 THEN RAISE EXCEPTION 'Old Excel erased VAT'; END IF;
 -- New per-item snapshot survives menu edits between partial payments.
 INSERT INTO orders(restaurant_id) VALUES(store) RETURNING id INTO ord;
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,display_name)
 VALUES(store,ord,coke.id,100000,1,'Coca-Cola') RETURNING id INTO line;
 IF public.calculate_order_discountable_total(ord,store)<>110000 THEN RAISE EXCEPTION 'Discount base ignores sugar VAT'; END IF;
 paid:=public.process_payment_without_scoped_promotions(ord,store,50000,'CASH');
 PERFORM public.admin_set_menu_beverage_tax(coke.id,'{"beverage_sugar_tax_class":"lte_5","sugar_g_per_100ml":0}');
 paid:=public.process_payment_without_scoped_promotions(ord,store,60000,'CASH');
 IF (SELECT status FROM orders WHERE id=ord)<>'completed' OR (SELECT vat_rate FROM order_items WHERE id=line)<>10 THEN
   RAISE EXCEPTION 'Partial payment repriced after menu edit'; END IF;
 -- Fresh line reflects the updated setting.
 INSERT INTO orders(restaurant_id) VALUES(store) RETURNING id INTO ord;
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,display_name)
 VALUES(store,ord,coke.id,100000,1,'New Coca-Cola') RETURNING id INTO line;
 IF (SELECT vat_rate FROM order_items WHERE id=line)<>8 THEN RAISE EXCEPTION 'New line did not adopt new VAT'; END IF;
 PERFORM public.admin_set_menu_beverage_tax(coke.id,'{"beverage_sugar_tax_class":"gt_5","sugar_g_per_100ml":5.01}');
 combo:=public.admin_create_menu_item_with_tax(store,category,'콤보','Combo','Combo',NULL,200000,
   '{"beverage_sugar_tax_class":"not_applicable"}');
 UPDATE menu_items SET is_combo=true WHERE id=combo.id;
 -- Fixed combos and direct orders freeze the same profile before quoting.
 INSERT INTO menu_combo_components VALUES(store,combo.id,food.id,1),(store,combo.id,coke.id,1);
 INSERT INTO direct_order_request_items(request_id,restaurant_id,menu_item_id,unit_price,quantity)
 VALUES(request_id,store,coke.id,100000,1),(request_id,store,combo.id,200000,1);
 IF (SELECT jsonb_array_length(vat_profile_snapshot) FROM direct_order_request_items
     WHERE menu_item_id=combo.id)<>2 THEN RAISE EXCEPTION 'Fixed combo lost VAT buckets'; END IF;
 PERFORM public.admin_set_menu_beverage_tax(coke.id,'{"beverage_sugar_tax_class":"lte_5","sugar_g_per_100ml":0}');
 INSERT INTO orders(restaurant_id) VALUES(store) RETURNING id INTO ord;
 PERFORM set_config('pos.direct_vat_request',request_id::text,true);
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,display_name)
 VALUES(store,ord,coke.id,100000,1,'Quoted Coca-Cola') RETURNING id INTO line;
 PERFORM set_config('pos.direct_vat_request','',true);
 IF (SELECT vat_rate FROM order_items WHERE id=line)<>10 THEN RAISE EXCEPTION 'Direct approval lost quoted VAT'; END IF;
 PERFORM public.admin_set_menu_beverage_tax(coke.id,'{"beverage_sugar_tax_class":"gt_5","sugar_g_per_100ml":5.01}');
 -- A scheduled promotion uses per-item discount allocation before invoice capture.
 INSERT INTO orders(restaurant_id) VALUES(store) RETURNING id INTO ord;
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,display_name,combo_components)
 VALUES(store,ord,combo.id,200000,1,'Combo',jsonb_build_array(
   jsonb_build_object('menu_item_id',food.id,'quantity',1),jsonb_build_object('menu_item_id',coke.id,'quantity',1))) RETURNING id INTO line;
 INSERT INTO store_promotions(restaurant_id,name,discount_percent) VALUES(store,'Happy hour',10);
 SELECT (public.sync_active_order_promotion(ord,store)).id INTO discount_id;
 IF (SELECT discount_amount FROM order_discounts WHERE id=discount_id)<>21800
 OR (SELECT line_amount_before_discount FROM order_discount_lines WHERE order_discount_id=discount_id)<>218000 THEN
   RAISE EXCEPTION 'Promotion still priced mixed combo at food VAT'; END IF;
 paid:=public.process_payment_before_promotion_read_split(ord,store,196200,'CASH');
 SELECT lines INTO captured FROM captured_invoice WHERE order_id=ord;
 IF (captured->0->>'paying_amount_inc_tax')::numeric<>196200 OR (captured->0->>'vat_amount')::numeric<>16200 THEN
   RAISE EXCEPTION 'Invoice captured incorrect mixed/discounted total: %',captured; END IF;
 SELECT sum(t.paying_amount_inc_tax),sum(t.vat_amount) INTO amount,vat
 FROM order_items i CROSS JOIN LATERAL public.order_item_invoice_tax_lines(i) t WHERE i.id=line;
 IF amount<>196200 OR vat<>16200 THEN RAISE EXCEPTION 'Invoice slices lose amount'; END IF;
 IF EXISTS(SELECT 1 FROM order_items i CROSS JOIN LATERAL public.order_item_invoice_tax_lines(i) t WHERE i.id=line AND t.vat_rate NOT IN (8,10)) THEN
   RAISE EXCEPTION 'Internal mixed VAT marker leaked into invoice'; END IF;
 -- Service charge must follow tax buckets, including a non-alcoholic 10% drink.
 UPDATE brands SET service_charge_enabled=true,service_charge_rate=5 WHERE id=brand;
 INSERT INTO orders(restaurant_id) VALUES(store) RETURNING id INTO ord;
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,display_name,combo_components)
 VALUES(store,ord,combo.id,200000,1,'Combo',jsonb_build_array(
   jsonb_build_object('menu_item_id',food.id,'quantity',1),jsonb_build_object('menu_item_id',coke.id,'quantity',1)));
 paid:=public.process_payment_without_scoped_promotions(ord,store,228900,'CASH');
 IF (SELECT sum(paying_amount_inc_tax) FROM order_items WHERE order_id=ord AND item_type='service_charge')<>10900 THEN
   RAISE EXCEPTION 'Service charge VAT buckets incorrect'; END IF;
 -- Execute the actual quote function with the request's frozen mixed profile.
 UPDATE menu_items SET is_visible_public=true WHERE id IN(coke.id,combo.id);
 INSERT INTO direct_order_requests(id,restaurant_id) VALUES(request_id,store);
 INSERT INTO direct_order_storefronts(restaurant_id) VALUES(store);
 PERFORM public.admin_set_menu_beverage_tax(coke.id,'{"beverage_sugar_tax_class":"lte_5","sugar_g_per_100ml":0}');
 captured:=public.direct_order_staff_quote(store,request_id,0,NULL);
 IF (captured->>'menu_total')::numeric<>328000
 OR (captured->>'service_charge_total')::numeric<>16400
 OR (captured->>'final_total')::numeric<>344400 THEN
   RAISE EXCEPTION 'Direct quote does not match frozen Coke/Combo/SC rates: %',captured; END IF;
 RAISE NOTICE 'PASS: menu validation, atomic edit, permissions, Excel preservation, partial payments, mixed combo/promotion/invoice/service charge';
END $test$;
ROLLBACK;
