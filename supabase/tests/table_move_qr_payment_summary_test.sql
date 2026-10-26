\set ON_ERROR_STOP on
BEGIN;
DO $$ DECLARE shop uuid; menu uuid; src uuid:=gen_random_uuid(); dst uuid:=gen_random_uuid(); o uuid; item uuid; r jsonb; op uuid:=gen_random_uuid(); target uuid; before_total numeric; p jsonb; token text:='isolated-qr-balance'; BEGIN
 SELECT restaurant_id,menu_item_id INTO shop,menu FROM public.order_items LIMIT 1;
 UPDATE public.order_discounts SET status='voided' WHERE status='active';
 INSERT INTO public.tables(id,restaurant_id,table_number,floor_label,status) VALUES(src,shop,'qr-source','2F','occupied'),(dst,shop,'qr-destination','3F','available');
 INSERT INTO public.table_qr_tokens VALUES(token,shop,src,true);
 INSERT INTO public.orders(restaurant_id,table_id,status,sales_channel) VALUES(shop,src,'serving','dine_in') RETURNING id INTO o;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,label,status,vat_rate,vat_profile_snapshot,paying_amount_inc_tax,vat_amount,total_amount_ex_tax)
 VALUES(shop,o,menu,18000,4,'Four drinks','served',8,'[{"rate":8,"weight":1}]',77760,5760,72000) RETURNING id INTO item;
 UPDATE public.restaurants SET vat_pricing_mode='exclusive' WHERE id=shop;
 UPDATE public.brands SET service_charge_enabled=false WHERE id=(SELECT brand_id FROM restaurants WHERE id=shop);
 p:=public.qr_get_active_order(token)->'payment_summary';
 ASSERT (p->>'remaining_due')::numeric=77760,'served menu disappeared from balance';
 ASSERT p->>'currency'='VND';
 before_total:=(p->>'total_amount')::numeric;
 -- Enable the actual extension only after fixture initialization. Temp-table
 -- updates in the production movement function must obey it as well.
 EXECUTE 'LOAD ''safeupdate''';
 PERFORM set_config('safeupdate.enabled','1',true);
 r:=public.cashier_move_order_items(shop,o,dst,jsonb_build_array(jsonb_build_object('item_id',item,'quantity',1,'expected_quantity',4)),op);
 ASSERT r=public.cashier_move_order_items(shop,o,dst,jsonb_build_array(jsonb_build_object('item_id',item,'quantity',1,'expected_quantity',4)),op),'movement retry duplicated';
 target:=(r->>'target_order_id')::uuid;
 ASSERT (public.qr_table_payment_summary(shop,src)->>'remaining_due')::numeric=58320;
 ASSERT (public.qr_table_payment_summary(shop,dst)->>'remaining_due')::numeric=19440;
 ASSERT (public.qr_table_payment_summary(shop,src)->>'total_amount')::numeric+(public.qr_table_payment_summary(shop,dst)->>'total_amount')::numeric=before_total,'move changed money';
 ASSERT (SELECT sum(quantity)=4 FROM order_items WHERE order_id IN(o,target)),'move changed quantity';
 -- Same table's second current order must contribute; a closed/other table must not.
 INSERT INTO public.orders(restaurant_id,table_id,status,sales_channel) VALUES(shop,src,'confirmed','dine_in') RETURNING id INTO o;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,label,status,vat_rate,vat_profile_snapshot)
 VALUES(shop,o,menu,10000,1,'Additional order','pending',10,'[{"rate":10,"weight":1}]');
 p:=public.qr_get_active_order(token)->'payment_summary';
 ASSERT (p->>'order_count')::int=2 AND (p->>'remaining_due')::numeric=69320,'latest-order-only total';
 INSERT INTO public.payments(order_id,restaurant_id,amount,amount_portion,method,is_revenue) VALUES(o,shop,5000,5000,'CASH',true);
 ASSERT (public.qr_get_active_order(token)->'payment_summary'->>'remaining_due')::numeric=64320,'partial payment not subtracted';
 UPDATE public.orders SET operational_closed_at=now() WHERE id=o;
 ASSERT (public.qr_table_payment_summary(shop,src)->>'remaining_due')::numeric=58320,'closed order counted';
 BEGIN PERFORM public.qr_get_active_order('invalid-token'); RAISE EXCEPTION 'INVALID_TOKEN_ACCEPTED'; EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='QR_TOKEN_INVALID',SQLERRM; END;
 ASSERT (public.qr_table_payment_summary(gen_random_uuid(),src)->>'remaining_due')::numeric=0,'cross-store amount leaked';
END $$;
DO $$ DECLARE shop uuid; menu uuid; tab uuid:=gen_random_uuid(); o uuid; f uuid; a uuid; disc uuid; p jsonb; BEGIN
 SELECT restaurant_id,menu_item_id INTO shop,menu FROM public.order_items LIMIT 1;
 INSERT INTO public.tables(id,restaurant_id,table_number,status) VALUES(tab,shop,'mixed-price','occupied');
 INSERT INTO public.orders(restaurant_id,table_id,status,sales_channel) VALUES(shop,tab,'serving','dine_in') RETURNING id INTO o;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,label,status,vat_rate,vat_profile_snapshot)
 VALUES(shop,o,menu,10000,2,'Food','served',8,'[{"rate":8,"weight":1}]') RETURNING id INTO f;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,label,status,vat_rate,vat_profile_snapshot)
 VALUES(shop,o,menu,10000,1,'Alcohol','ready',10,'[{"rate":10,"weight":1}]') RETURNING id INTO a;
 INSERT INTO public.order_items(restaurant_id,order_id,unit_price,quantity,label,status,item_type,vat_rate)
 VALUES(shop,o,2000,1,'Tissue','served','wet_tissue_charge',8);
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,label,status,is_service_item)
 VALUES(shop,o,menu,10000,1,'Free menu','served',true),(shop,o,menu,99900,1,'Cancelled','cancelled',false);
 UPDATE public.brands SET service_charge_enabled=true,service_charge_rate=5 WHERE id=(SELECT brand_id FROM restaurants WHERE id=shop);
 INSERT INTO public.order_discounts(order_id,restaurant_id,status,discount_mode,discount_value,discount_amount,approved_via)
 VALUES(o,shop,'active','percent',10,3260,'scheduled_promotion') RETURNING id INTO disc;
 INSERT INTO public.order_discount_lines VALUES(disc,f,2160),(disc,a,1100);
 INSERT INTO public.payments(order_id,restaurant_id,amount,amount_portion,method,is_revenue) VALUES(o,shop,1000,1000,'CASH',true);
 p:=public.qr_table_payment_summary(shop,tab);
 ASSERT (p->>'total_amount')::numeric=33130 AND (p->>'remaining_due')::numeric=32130,p::text;
 UPDATE public.restaurants SET vat_pricing_mode='inclusive' WHERE id=shop;
 UPDATE public.order_discounts SET discount_amount=3000 WHERE id=disc;
 UPDATE public.order_discount_lines SET discount_amount=2000 WHERE order_discount_id=disc AND order_item_id=f;
 UPDATE public.order_discount_lines SET discount_amount=1000 WHERE order_discount_id=disc AND order_item_id=a;
 p:=public.qr_table_payment_summary(shop,tab);
 ASSERT (p->>'total_amount')::numeric=30500.01 AND (p->>'remaining_due')::numeric=29500.01,p::text;
 UPDATE public.orders SET status='completed' WHERE id=o;
 ASSERT (public.qr_table_payment_summary(shop,tab)->>'remaining_due')::numeric=0,'paid order retained';
END $$;
DO $$ DECLARE shop uuid; menu uuid; tab uuid:=gen_random_uuid(); o uuid; n int; started timestamptz; p jsonb; BEGIN
 SELECT restaurant_id,menu_item_id INTO shop,menu FROM public.order_items LIMIT 1;
 UPDATE public.restaurants SET vat_pricing_mode='exclusive' WHERE id=shop;
 UPDATE public.brands SET service_charge_enabled=false WHERE id=(SELECT brand_id FROM restaurants WHERE id=shop);
 INSERT INTO public.tables(id,restaurant_id,table_number,status) VALUES(tab,shop,'scale-quote','occupied');
 FOREACH n IN ARRAY ARRAY[1,50,500] LOOP
  INSERT INTO public.orders(restaurant_id,table_id,status,sales_channel) VALUES(shop,tab,'serving','dine_in') RETURNING id INTO o;
  INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,label,status,vat_rate,vat_profile_snapshot)
  SELECT shop,o,menu,1000,1,'Scale','served',8,'[{"rate":8,"weight":1}]' FROM generate_series(1,n);
  started:=clock_timestamp();
  p:=public.qr_table_payment_summary(shop,tab);
  ASSERT (p->>'remaining_due')::numeric=n*1080,p::text;
  RAISE NOTICE 'QR_BALANCE_MEASUREMENT active_lines=% rpc_calls=1 summary_bytes=% elapsed_ms=%',n,octet_length(p::text),round(extract(epoch FROM clock_timestamp()-started)*1000,3);
  UPDATE public.orders SET operational_closed_at=now() WHERE id=o;
 END LOOP;
END $$;
SELECT 'TABLE_MOVE_QR_BALANCE=PASS safeupdate=on served=PASS partial_payment=PASS multi_order=PASS isolation=PASS';
ROLLBACK;
