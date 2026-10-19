-- These are isolated fixture identities, not operating menu or receipt IDs.
DO $no_fee$
DECLARE f jsonb; shop uuid; request uuid; o uuid; financial jsonb; total numeric;
 legacy recipient_measurement.legacy%ROWTYPE; original_financial jsonb; original_quote jsonb;
BEGIN
 SELECT * INTO legacy FROM recipient_measurement.legacy;
 SELECT to_jsonb(x) INTO original_financial FROM public.direct_order_financials x WHERE x.request_id=legacy.request_id;
 SELECT to_jsonb(x) INTO original_quote FROM public.direct_order_quotes x WHERE x.request_id=legacy.request_id;
 f:=photo_test.create_request(true,'customer_direct');
 shop:=(f->>'store_id')::uuid;request:=(f->>'request_id')::uuid;
 UPDATE public.users SET restaurant_id=shop WHERE auth_id=auth.uid();
 PERFORM photo_test.approve(f);
 SELECT to_jsonb(x),x.order_id,x.final_total INTO financial,o,total FROM public.direct_order_financials x WHERE x.request_id=request;
 IF financial->>'delivery_fee_item_id' IS NOT NULL OR (financial->>'delivery_fee_total')::numeric<>0
  OR EXISTS(SELECT 1 FROM public.order_items WHERE order_id=o AND public.pos_is_delivery_fee_item(item_type,menu_item_id,display_name,label))
  OR total<>108000 OR (SELECT sum(paying_amount_inc_tax) FROM public.order_items WHERE order_id=o AND status<>'cancelled')<>total
 THEN RAISE EXCEPTION 'NEW_ORDER_MANUFACTURED_DELIVERY_ITEM'; END IF;
 PERFORM photo_test.approve(f);
 IF financial IS DISTINCT FROM (SELECT to_jsonb(x) FROM public.direct_order_financials x WHERE x.request_id=request)
 THEN RAISE EXCEPTION 'NO_FEE_PAYMENT_RETRY_CHANGED'; END IF;
 PERFORM public.direct_order_post_delivery_advance(request,shop);
 BEGIN
  INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,item_type,label,display_name,unit_price,quantity,status,
   vat_rate,vat_amount,total_amount_ex_tax,paying_amount_inc_tax,is_service_item,fulfillment_mode_snapshot)
  VALUES(shop,o,NULL,'service_charge','Phí giao hàng','Phí giao hàng',0,1,'served',0,0,0,0,false,'pos_print');
  RAISE EXCEPTION 'ZERO_DELIVERY_PLACEHOLDER_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DELIVERY_FEE_DISABLED' THEN RAISE; END IF; END;
 BEGIN
  INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,item_type,label,display_name,unit_price,quantity,status,
   vat_rate,vat_amount,total_amount_ex_tax,paying_amount_inc_tax,is_service_item,fulfillment_mode_snapshot)
  VALUES(shop,o,NULL,'service_charge','Delivery fee','Delivery fee',10000,1,'served',0,0,10000,10000,false,'pos_print');
  RAISE EXCEPTION 'POSITIVE_DELIVERY_ITEM_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DELIVERY_FEE_DISABLED' THEN RAISE; END IF; END;
 BEGIN
  INSERT INTO public.direct_order_quotes SELECT (jsonb_populate_record(NULL::public.direct_order_quotes,
   original_quote||jsonb_build_object('id',gen_random_uuid(),'version',99999,'status','superseded',
    'delivery_fee_total',1000,'delivery_fee_pretax',1000,'delivery_fee_vat',0))).*;
  RAISE EXCEPTION 'LEGACY_PATH_CREATED_NEW_DELIVERY_QUOTE';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DELIVERY_FEE_DISABLED' THEN RAISE; END IF; END;
 BEGIN
  INSERT INTO public.direct_order_payment_charges(request_id,restaurant_id,kind,amount,reason,status,created_by)
  SELECT legacy.request_id,x.restaurant_id,'delivery',1000,'new charge not allowed','pending',auth.uid()
  FROM public.direct_order_requests x WHERE x.id=legacy.request_id;
  RAISE EXCEPTION 'LEGACY_PATH_CREATED_NEW_DELIVERY_CHARGE';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DELIVERY_FEE_DISABLED' THEN RAISE; END IF; END;
 IF original_financial IS DISTINCT FROM (SELECT to_jsonb(x) FROM public.direct_order_financials x WHERE x.request_id=legacy.request_id)
  OR original_quote IS DISTINCT FROM (SELECT to_jsonb(x) FROM public.direct_order_quotes x WHERE x.request_id=legacy.request_id)
  OR legacy.snapshot IS DISTINCT FROM (SELECT snapshot FROM public.digital_receipts WHERE id=legacy.receipt_id)
 THEN RAISE EXCEPTION 'NO_FEE_POLICY_CHANGED_ISSUED_HISTORY'; END IF;
END $no_fee$;
