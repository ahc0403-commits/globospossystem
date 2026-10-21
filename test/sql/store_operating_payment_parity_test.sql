-- Compare the exact pre-upgrade promotion wrapper/core with the new batch on
-- the same order IDs. A subtransaction rolls the old run back before replay.
BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
CREATE FUNCTION operating_test.payment_outcome(oid uuid,shop uuid,legacy boolean) RETURNS jsonb
LANGUAGE plpgsql AS $$ DECLARE remaining numeric; initial numeric:=1; result jsonb; BEGIN
 IF EXISTS(SELECT 1 FROM public.order_discounts d JOIN public.restaurants r ON r.id=d.restaurant_id
 JOIN public.brands b ON b.id=r.brand_id WHERE d.order_id=oid AND d.discount_mode='percent' AND d.discount_value=100
 AND NOT coalesce(b.service_charge_enabled,false)) THEN initial:=0; END IF;
 IF legacy THEN PERFORM operating_test.payment_wrapper_before_operating(oid,shop,initial,'CASH');
 ELSE PERFORM public.process_payment_before_promotion_read_split(oid,shop,initial,'CASH'); END IF;
 SELECT sum(paying_amount_inc_tax)-initial INTO remaining FROM public.order_items WHERE order_id=oid AND status<>'cancelled';
 IF (SELECT status<>'completed' FROM public.orders WHERE id=oid) THEN
 IF legacy THEN PERFORM operating_test.payment_wrapper_before_operating(oid,shop,remaining,'BANKTRANSFER');
 ELSE PERFORM public.process_payment_before_promotion_read_split(oid,shop,remaining,'BANKTRANSFER'); END IF;
 END IF;
 SELECT jsonb_build_object(
  'status',(SELECT status FROM public.orders WHERE id=oid),
  'lines',(SELECT jsonb_agg(jsonb_build_object('type',item_type,'menu',menu_item_id,'label',label,'name',display_name,
   'price',unit_price,'quantity',quantity,'service',is_service_item,'status',status,'supply',total_amount_ex_tax,
   'vat',vat_amount,'rate',vat_rate,'total',paying_amount_inc_tax,'breakdown',vat_breakdown,'profile',vat_profile_snapshot)
   ORDER BY item_type,label,unit_price,quantity,display_name) FROM public.order_items WHERE order_id=oid),
  'discount',(SELECT jsonb_agg(jsonb_build_array(discount_mode,discount_value,discount_amount,status)) FROM public.order_discounts WHERE order_id=oid),
  'payments',(SELECT jsonb_agg(jsonb_build_array(method,amount,is_revenue) ORDER BY method) FROM public.payments WHERE order_id=oid),
  'journal',(SELECT jsonb_agg(jsonb_build_array(ingredient_id,reference_id,quantity_g) ORDER BY ingredient_id,reference_id)
    FROM public.inventory_transactions WHERE reference_id IN(SELECT id FROM public.order_items WHERE order_id=oid)),
  'invoice',(SELECT jsonb_agg(status ORDER BY status) FROM public.meinvoice_jobs WHERE order_id=oid)
 ) INTO result;
 RETURN result;
END $$;
DO $$ DECLARE shop uuid:='8bc9eef5-dcd5-46b1-b931-23f77132322c'; food uuid; alcohol uuid; alcohol_category uuid; stock uuid;
 oid uuid; iid uuid; discount uuid; scenario record; old_result jsonb; new_result jsonb;
BEGIN
 PERFORM public.approve_invoice_mapping_policy(shop,'91000000-0000-4000-8000-000000000004',
  'payment-parity-fixture','{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','Isolated payment parity');
 INSERT INTO public.menu_items(restaurant_id,name,name_vi,invoice_sale_unit,price,vat_category)
 VALUES(shop,'Parity food','Món thử so sánh','Phần',101.01,'food') RETURNING id INTO food;
 INSERT INTO public.menu_categories(restaurant_id,name,name_ko,name_vi,name_en,system_key) VALUES(shop,'주류','주류','Đồ uống có cồn','Alcohol','alcohol') RETURNING id INTO alcohol_category;
 INSERT INTO public.menu_items(category_id,restaurant_id,name,name_vi,invoice_sale_unit,price,vat_category)
 VALUES(alcohol_category,shop,'Parity alcohol','Rượu thử so sánh','Phần',77.77,'alcohol') RETURNING id INTO alcohol;
 ASSERT (SELECT effective_vat_rate=10 FROM public.menu_items WHERE id=alcohol),'mixed tax fixture invalid';
 INSERT INTO public.inventory_items(restaurant_id,name,unit,current_stock) VALUES(shop,'Parity ingredient','g',100000) RETURNING id INTO stock;
 INSERT INTO public.menu_recipes(restaurant_id,menu_item_id,ingredient_id,quantity_g) VALUES(shop,food,stock,1.234),(shop,alcohol,stock,2.345);
 FOR scenario IN SELECT mode,service,discount_mode FROM unnest(ARRAY['exclusive','inclusive']) mode
 CROSS JOIN unnest(ARRAY[false,true]) service CROSS JOIN unnest(ARRAY['none','percent','amount','targeted','full']) discount_mode LOOP
  UPDATE public.restaurants SET vat_pricing_mode=scenario.mode WHERE id=shop;
  UPDATE public.brands SET service_charge_enabled=scenario.service,service_charge_rate=3.17
  WHERE id='91000000-0000-4000-8000-000000000003';
  INSERT INTO public.orders(restaurant_id,status) VALUES(shop,'serving') RETURNING id INTO oid;
  INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,item_type,label,display_name,unit_price,quantity,status)
  VALUES(shop,oid,food,'menu_item','Parity food','Parity food',101.01,3,'served') RETURNING id INTO iid;
  INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,item_type,label,display_name,unit_price,quantity,status,is_service_item)
  VALUES(shop,oid,alcohol,'menu_item','Parity alcohol','Parity alcohol',77.77,2,'served',false),
   (shop,oid,food,'menu_item','Parity extra','Parity extra',33.33,1,'served',false),
   (shop,oid,food,'menu_item','Complimentary','Complimentary',23.45,1,'served',true);
  INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,item_type,label,display_name,unit_price,quantity,status,cancelled_consumed_quantity)
  VALUES(shop,oid,food,'menu_item','Cancelled','Cancelled',33.33,2,'cancelled',1);
  IF scenario.discount_mode<>'none' THEN
   INSERT INTO public.order_discounts(restaurant_id,order_id,discount_type,discount_mode,discount_value,discount_amount,
    proof_storage_path,applied_by,approved_via,reason)
   VALUES(shop,oid,'manual',CASE WHEN scenario.discount_mode IN ('percent','full') THEN 'percent' ELSE 'amount' END,
    CASE WHEN scenario.discount_mode='full' THEN 100 WHEN scenario.discount_mode='percent' THEN 13.37 ELSE 5.01 END,
    CASE WHEN scenario.discount_mode='targeted' THEN 5.01 ELSE 0 END,'fixture/proof',auth.uid(),
    CASE WHEN scenario.discount_mode='targeted' THEN 'scheduled_promotion' ELSE 'manager_pin' END,'Isolated differential fixture') RETURNING id INTO discount;
   IF scenario.discount_mode='targeted' THEN
    INSERT INTO public.order_discount_lines(order_discount_id,restaurant_id,order_item_id,menu_item_id,line_amount_before_discount,discount_percent,discount_amount)
    VALUES(discount,shop,iid,food,CASE WHEN scenario.mode='inclusive' THEN 303.03 ELSE 327.27 END,2,5.01);
   END IF;
  END IF;
  BEGIN
   old_result:=operating_test.payment_outcome(oid,shop,true);
   RAISE EXCEPTION USING ERRCODE='P1999',MESSAGE='rollback comparison baseline';
  EXCEPTION WHEN SQLSTATE 'P1999' THEN NULL; END;
  ASSERT NOT EXISTS(SELECT 1 FROM public.payments WHERE order_id=oid),'baseline did not roll back';
  new_result:=operating_test.payment_outcome(oid,shop,false);
  ASSERT old_result=new_result,format('payment parity mismatch mode=%s service=%s discount=%s old=%s new=%s',
   scenario.mode,scenario.service,scenario.discount_mode,old_result,new_result);
  RAISE NOTICE 'PAYMENT_PARITY=PASS mode=% service=% discount=%',scenario.mode,scenario.service,scenario.discount_mode;
 END LOOP;
END $$;
ROLLBACK;
