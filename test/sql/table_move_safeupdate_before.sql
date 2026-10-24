\set ON_ERROR_STOP on
BEGIN;
DO $$ DECLARE shop uuid; menu uuid; src uuid:=gen_random_uuid(); dst uuid:=gen_random_uuid(); o uuid; i uuid; op uuid:=gen_random_uuid(); BEGIN
 SELECT restaurant_id,menu_item_id INTO shop,menu FROM public.order_items LIMIT 1;
 INSERT INTO public.tables(id,restaurant_id,table_number,status) VALUES(src,shop,'before-source','occupied'),(dst,shop,'before-destination','available');
 INSERT INTO public.orders(restaurant_id,table_id,status,sales_channel) VALUES(shop,src,'serving','dine_in') RETURNING id INTO o;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,unit_price,quantity,label,status,vat_rate,paying_amount_inc_tax,vat_amount,total_amount_ex_tax)
 VALUES(shop,o,menu,10000,1,'Before move','served',8,10800,800,10000) RETURNING id INTO i;
 EXECUTE 'LOAD ''safeupdate''';
 PERFORM set_config('safeupdate.enabled','1',true);
 BEGIN
  PERFORM public.cashier_move_order_items(shop,o,dst,jsonb_build_array(jsonb_build_object('item_id',i,'quantity',1,'expected_quantity',1)),op);
  RAISE EXCEPTION 'EXPECTED_SAFEUPDATE_FAILURE_MISSING';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='UPDATE requires a WHERE clause',SQLERRM;
 END;
 ASSERT (SELECT quantity=1 AND order_id=o FROM public.order_items WHERE id=i),'failed move altered source';
 ASSERT NOT EXISTS(SELECT 1 FROM public.orders WHERE table_id=dst),'failed move left target order';
 ASSERT NOT EXISTS(SELECT 1 FROM public.cashier_item_operations WHERE id=op),'failed move recorded success';
END $$;
SELECT 'TABLE_MOVE_BEFORE=REPRODUCED atomic_rollback=PASS';
ROLLBACK;
