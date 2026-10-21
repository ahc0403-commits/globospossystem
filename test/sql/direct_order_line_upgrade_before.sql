-- Persist both an approved and an awaiting-review legacy request across DDL.
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',false);
CREATE TABLE operating_test.direct_line_upgrade(
 request_id uuid PRIMARY KEY,quote_id uuid,proof_id uuid,request_line_id uuid,
 old_order_line_id uuid,was_approved boolean,reference text
);
DO $$ DECLARE shop uuid:='273b057e-3b69-46e3-93c1-6194c2802849'; menu uuid; sid uuid;
 hash text:=repeat('b',64); rid uuid; q jsonb; proof uuid; old_line uuid; n integer;
BEGIN
 PERFORM public.approve_invoice_mapping_policy(shop,'91000000-0000-4000-8000-000000000004',
  'pending-upgrade-fixture','{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','Isolated pending request regression');
 INSERT INTO public.menu_items(restaurant_id,name,name_vi,price,invoice_sale_unit,is_visible_public)
 VALUES(shop,'Pending fixture','Món đang chờ',10000,'Phần',true) RETURNING id INTO menu;
 INSERT INTO public.direct_order_storefronts(restaurant_id,public_slug,is_enabled,ordering_hours_enforced,
  bank_bin,bank_account_number,bank_account_holder,accounting_approved_at,accounting_approved_by)
 VALUES(shop,'pending-line-fixture',true,false,'000000','FIXTURE123','Fixture account',now(),auth.uid());
 INSERT INTO public.direct_order_sessions(restaurant_id,secret_hash,locale) VALUES(shop,hash,'vi') RETURNING id INTO sid;
 FOR n IN 1..2 LOOP
  rid:=(public.direct_order_public_submit_v3(sid,hash,gen_random_uuid(),jsonb_build_object(
   'locale','vi','fulfillment_type','pickup','diner_count',1,
   'address',jsonb_build_object('customer_name','Fixture only','customer_phone','0901234567','address_source','pickup'),
   'items',jsonb_build_array(jsonb_build_object('menu_item_id',menu,'quantity',1))))->>'request_id')::uuid;
  q:=public.direct_order_staff_quote_with_payment_mode(shop,rid,0,NULL,'customer_direct');
  UPDATE public.direct_order_requests SET state='awaiting_payment_review' WHERE id=rid;
  UPDATE public.direct_order_quotes SET status='locked' WHERE id=(q->>'id')::uuid;
  INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path,metadata)
  VALUES(rid,shop,'customer','payment_proof','Fixture proof',shop::text||'/'||rid::text||'/'||gen_random_uuid()::text||'.jpg',
   jsonb_build_object('quote_id',q->>'id','quote_version','1')) RETURNING id INTO proof;
  old_line:=NULL;
  IF n=1 THEN
   PERFORM public.direct_order_record_receipt(shop,rid,(q->>'id')::uuid,proof,10800,'Fixture-'||rid::text);
   SELECT i.id INTO old_line FROM public.direct_order_financials f JOIN public.order_items i ON i.order_id=f.order_id
   WHERE f.request_id=rid AND i.menu_item_id=menu;
   ASSERT old_line<>(SELECT id FROM public.direct_order_request_items WHERE request_id=rid), 'legacy fixture used new identity';
  END IF;
  INSERT INTO operating_test.direct_line_upgrade
  SELECT rid,(q->>'id')::uuid,proof,id,old_line,n=1,'Fixture-'||rid::text FROM public.direct_order_request_items WHERE request_id=rid;
 END LOOP;
END $$;
