DO $$ BEGIN
 IF current_database() <> 'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
END $$;
CREATE SCHEMA photo_test;
INSERT INTO public.brands(id) VALUES('d1000000-0000-4000-8000-000000000001');
INSERT INTO public.restaurants(id,brand_id,vat_pricing_mode)
 VALUES('d1000000-0000-4000-8000-000000000002','d1000000-0000-4000-8000-000000000001','exclusive');
UPDATE public.users SET restaurant_id='d1000000-0000-4000-8000-000000000002' WHERE auth_id=auth.uid();
INSERT INTO public.users(auth_id,role,is_active,restaurant_id) VALUES('00000000-0000-4000-8000-000000000002','kitchen',true,'d1000000-0000-4000-8000-000000000002');
INSERT INTO public.restaurant_settings VALUES('d1000000-0000-4000-8000-000000000002','pos_print');
INSERT INTO public.direct_order_storefronts(restaurant_id,public_slug,is_enabled,ordering_starts_at,ordering_cutoff_at,
 bank_bin,bank_account_number,bank_account_holder,accounting_approved_at,accounting_approved_by)
 VALUES('d1000000-0000-4000-8000-000000000002','photo-test',true,'00:00','21:30','970457','1234567890','PHOTO TEST',now(),auth.uid());
INSERT INTO public.menu_items(id,restaurant_id,vat_category,name,name_ko,name_vi,name_en,price)
 VALUES('d1000000-0000-4000-8000-000000000003','d1000000-0000-4000-8000-000000000002','food','Photo test menu','사진 테스트','Món thử','Photo test menu',100000);
INSERT INTO public.inventory_items(id,restaurant_id,current_stock)
 VALUES('d1000000-0000-4000-8000-000000000004','d1000000-0000-4000-8000-000000000002',10000);
INSERT INTO public.menu_recipes VALUES('d1000000-0000-4000-8000-000000000003','d1000000-0000-4000-8000-000000000002','d1000000-0000-4000-8000-000000000004',10);
CREATE FUNCTION photo_test.create_request(p_photo boolean DEFAULT true,p_delivery_mode text DEFAULT 'customer_direct',p_fulfillment text DEFAULT 'delivery') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
 v_store uuid := 'd1000000-0000-4000-8000-000000000002';
 v_session uuid; v_request uuid; v_quote uuid; v_proof uuid;
BEGIN
 INSERT INTO public.direct_order_sessions(restaurant_id,secret_hash,locale)
 VALUES(v_store,repeat(replace(gen_random_uuid()::text,'-',''),2),'vi') RETURNING id INTO v_session;
 INSERT INTO public.direct_order_requests(restaurant_id,session_id,client_request_id,reference_code,state,locale,fulfillment_type)
 VALUES(v_store,v_session,gen_random_uuid(),'D'||upper(left(replace(gen_random_uuid()::text,'-',''),8)),'awaiting_payment_review','vi',p_fulfillment) RETURNING id INTO v_request;
 INSERT INTO public.direct_order_request_items(request_id,restaurant_id,menu_item_id,display_name,name_ko,name_vi,name_en,vat_category,unit_price,quantity)
 VALUES(v_request,v_store,'d1000000-0000-4000-8000-000000000003','Photo test menu','사진 테스트','Món thử','Photo test menu','food',100000,1);
 INSERT INTO public.direct_order_quotes(request_id,restaurant_id,version,menu_pretax,menu_vat,menu_total,
 service_charge_pretax,service_charge_vat,service_charge_total,delivery_fee_pretax,delivery_fee_vat,delivery_fee_total,final_total,delivery_fee_vat_rate,
 status,created_by,created_at,expires_at,locked_at,delivery_payment_mode)
 VALUES(v_request,v_store,1,100000,8000,108000,0,0,0,0,0,0,108000,8,'locked',auth.uid(),now()-interval '2 hours',now()-interval '1 hour',now()-interval '90 minutes',p_delivery_mode) RETURNING id INTO v_quote;
 IF p_photo THEN
  INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,attachment_storage_path,metadata)
  VALUES(v_request,v_store,'customer','payment_proof',v_store::text||'/'||v_request::text||'/'||gen_random_uuid()::text||'.jpg',
   jsonb_build_object('quote_id',v_quote,'quote_version',1)) RETURNING id INTO v_proof;
 END IF;
 RETURN jsonb_build_object('store_id',v_store,'request_id',v_request,'quote_id',v_quote,'proof_id',v_proof);
END $$;
CREATE FUNCTION photo_test.approve(f jsonb) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
 RETURN public.direct_order_approve_photo_payment((f->>'store_id')::uuid,(f->>'request_id')::uuid,108000,(f->>'quote_id')::uuid,(f->>'proof_id')::uuid);
END
$$;
CREATE FUNCTION photo_test.assert_empty_graph(p_request uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=p_request)
 OR EXISTS(SELECT 1 FROM public.direct_delivery_fulfillment_tickets WHERE request_id=p_request)
 OR EXISTS(SELECT 1 FROM public.orders o JOIN public.direct_order_requests r ON o.notes='Direct delivery '||r.reference_code WHERE r.id=p_request) THEN
 RAISE EXCEPTION 'UNAPPROVED_REQUEST_CREATED_FINANCIAL_GRAPH'; END IF;
END $$;
CREATE FUNCTION photo_test.assert_single_graph(p_request uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_order uuid;
BEGIN
 SELECT order_id INTO STRICT v_order FROM public.direct_order_financials WHERE request_id=p_request;
 IF (SELECT count(*) FROM public.payments WHERE order_id=v_order)<>1
 OR (SELECT count(*) FROM public.direct_delivery_fulfillment_tickets WHERE request_id=p_request)<>1
 OR (SELECT count(*) FROM public.direct_delivery_fulfillment_ticket_items i JOIN public.direct_delivery_fulfillment_tickets t ON i.ticket_id=t.id WHERE t.request_id=p_request AND i.quantity=1)<>1
 OR (SELECT count(*) FROM public.audit_logs WHERE entity_id=p_request AND action='direct_order_payment_approved' AND details->>'review_method'='customer_photo' AND details->>'proof_message_id' IS NOT NULL)<>1
 OR (SELECT count(*) FROM public.inventory_transactions tx JOIN public.order_items item ON item.id=tx.reference_id WHERE item.order_id=v_order)<>1
 OR NOT EXISTS(SELECT 1 FROM public.payments WHERE order_id=v_order AND method='BANKTRANSFER' AND amount_portion=108000)
 OR NOT EXISTS(SELECT 1 FROM public.orders WHERE id=v_order AND status='completed')
 OR NOT EXISTS(SELECT 1 FROM public.order_items WHERE order_id=v_order AND item_type='menu_item' AND vat_amount=8000 AND paying_amount_inc_tax=108000) THEN
 RAISE EXCEPTION 'PHOTO_APPROVAL_GRAPH_MISMATCH'; END IF;
 IF EXISTS(SELECT 1 FROM public.direct_order_financials f JOIN public.direct_order_quotes q ON q.id=f.quote_id WHERE f.request_id=p_request AND f.delivery_payment_mode<>q.delivery_payment_mode) THEN
 RAISE EXCEPTION 'DELIVERY_PAYMENT_MODE_NOT_SNAPSHOTTED'; END IF;
END $$;
