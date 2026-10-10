CREATE SCHEMA buyer_legacy;
CREATE TABLE buyer_legacy.scopes(kind text,fixture jsonb,order_id uuid);
DO $$ DECLARE f jsonb;o uuid;shop uuid;BEGIN
 f:=photo_test.create_request(true,'customer_direct');shop:=(f->>'store_id')::uuid;
 UPDATE public.users SET restaurant_id=shop WHERE auth_id=auth.uid();
 PERFORM photo_test.approve(f);SELECT order_id INTO o FROM public.direct_order_financials WHERE request_id=(f->>'request_id')::uuid;
 INSERT INTO public.red_invoice_intakes(order_id,store_id,tax_entity_id,receipt_ids,sale_at,gross_amount,payment_method,status,buyer_tax_code,
 buyer_legal_name,buyer_address,buyer_email,buyer_phone,buyer_unit_code,buyer_email_cc)
 SELECT o,shop,r.tax_entity_id,ARRAY[p.id::text],p.created_at,p.amount,p.method,'ready','00123456789-12','Legacy fixture company','Fixture address','legacy@example.invalid','0900000000','LEGACY-UNIT','cc@example.invalid'
 FROM public.restaurants r JOIN public.payments p ON p.order_id=o WHERE r.id=shop LIMIT 1;
 INSERT INTO buyer_legacy.scopes VALUES('invalid_ready',f,o);
 f:=photo_test.create_request(true,'customer_direct');
 UPDATE public.direct_order_requests SET invoice_details=jsonb_build_object('requested',true,'tax_code','00123456789-12','legal_name','Legacy wrong number','address','Fixture address','email','legacy@example.invalid','phone','0900000000') WHERE id=(f->>'request_id')::uuid;
 INSERT INTO buyer_legacy.scopes VALUES('legacy_pending',f,NULL);
END $$;
