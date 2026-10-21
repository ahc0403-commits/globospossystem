BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
-- Earlier upgrade fixtures deliberately retain pre-upgrade requests. Drain those
-- synthetic records inside this rolled-back test transaction.
UPDATE public.direct_order_requests SET state='cancelled';
UPDATE public.direct_delivery_fulfillment_tickets SET status='cancelled';
UPDATE public.order_items SET status='cancelled';
UPDATE public.orders SET status='cancelled';
UPDATE public.emergency_fulfillment_items SET is_cancelled=true;
UPDATE public.emergency_combo_component_items SET is_cancelled=true;
DO $$ DECLARE
 shop uuid:='273b057e-3b69-46e3-93c1-6194c2802849'; k1 uuid:=gen_random_uuid(); k2 uuid:=gen_random_uuid();
 a2 uuid:=gen_random_uuid(); u2 uuid:=gen_random_uuid(); definition jsonb; r jsonb; release uuid; m uuid; tab uuid; o public.orders; oi uuid;
 s1 uuid; s2 uuid; step public.store_preparation_steps; event uuid:=gen_random_uuid(); allocations jsonb; legacy uuid; q uuid; snapshot jsonb; moved uuid; target_table uuid; operation uuid; sid uuid; secret text:=md5(gen_random_uuid()::text)||md5(gen_random_uuid()::text); rid uuid; ticket public.direct_delivery_fulfillment_tickets; payload jsonb; quote jsonb; proof uuid; channel text;
BEGIN
 INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at) VALUES(a2,'workflow-kitchen2@internal.invalid','00000000-0000-0000-0000-000000000000','authenticated','authenticated',now());
 INSERT INTO public.users(id,auth_id,restaurant_id,role,full_name) VALUES(u2,a2,shop,'kitchen','Second kitchen');
 INSERT INTO public.emergency_station_assignments(restaurant_id,user_id,station_type,is_active) VALUES(shop,u2,'kitchen',true);
 PERFORM public.approve_invoice_mapping_policy(shop,'91000000-0000-4000-8000-000000000004','workflow-fixture','{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','isolated workflow approval');
 INSERT INTO public.menu_items(restaurant_id,name,name_vi,invoice_sale_unit,price) VALUES(shop,'Workflow dish','Món bếp','Phần',10000) RETURNING id INTO m;
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(shop,'1981','2F') RETURNING id INTO tab;
 definition:=jsonb_build_object('schema',1,'workflow','kitchen_floor','fulfillment_mode','paperless',
  'stations',jsonb_build_array(jsonb_build_object('id',k1,'name','주방 1','user_ids',jsonb_build_array('93000000-0000-4000-8000-000000000001')),
   jsonb_build_object('id',k2,'name','주방 2','user_ids',jsonb_build_array(u2))),
  'default_path',jsonb_build_array(k1,k2),'routes','[]'::jsonb);
 r:=public.admin_store_workflow_v1(shop,'save',0,definition);
 ASSERT (r->>'revision')::int=1;
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'save',0,definition); RAISE EXCEPTION 'STALE_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_CHANGED'; END;
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'publish',1); RAISE EXCEPTION 'UNVALIDATED_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_REVALIDATE'; END;
 r:=public.admin_store_workflow_v1(shop,'validate',1); ASSERT (r->'proof'->>'channel_cases')::int>0;
 r:=public.admin_store_workflow_v1(shop,'publish',2); release:=(r->>'candidate_id')::uuid;
 ASSERT (r->>'active_id') IS NULL,'publish switched live orders';
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'activate',3); RAISE EXCEPTION 'UNREADY_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_DEVICES_NOT_READY'; END;
 -- Actual actor acknowledgements for each required fixture account.
 FOR snapshot IN SELECT to_jsonb(u) FROM public.emergency_station_assignments a JOIN public.users u ON u.id=a.user_id WHERE a.restaurant_id=shop AND a.is_active LOOP
  PERFORM set_config('request.jwt.claim.sub',snapshot->>'auth_id',true);
  PERFORM public.store_workflow_device_v1(shop,gen_random_uuid(),release,0);
 END LOOP;
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
 r:=public.admin_store_workflow_v1(shop,'activate',3); ASSERT r->>'active_id'=release::text;

 UPDATE public.menu_items SET is_visible_public=true WHERE id=m;
 INSERT INTO public.direct_order_storefronts(restaurant_id,public_slug,is_enabled,ordering_hours_enforced,bank_bin,bank_account_number,bank_account_holder,accounting_approved_at,accounting_approved_by)
 VALUES(shop,'workflow-fixture',true,false,'000000','FIXTURE123','Fixture account',now(),auth.uid()) ON CONFLICT(restaurant_id) DO UPDATE SET is_paused=false,ordering_hours_enforced=false,minimum_order_amount=0;
 INSERT INTO public.direct_order_sessions(restaurant_id,secret_hash,locale) VALUES(shop,secret,'vi') RETURNING id INTO sid;
 FOREACH channel IN ARRAY ARRAY['pickup','delivery'] LOOP
  PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
  payload:=jsonb_build_object('locale','vi','fulfillment_type',channel,'diner_count',1,
   'items',jsonb_build_array(jsonb_build_object('menu_item_id',m,'menu_option_key',(SELECT menu_option_key FROM public.menu_items WHERE id=m),'quantity',2)),
   'address',jsonb_build_object('customer_name','Workflow fixture','customer_phone','0901234567','address_source',CASE channel WHEN 'pickup' THEN 'pickup' ELSE 'manual' END)||CASE channel WHEN 'pickup' THEN '{}'::jsonb ELSE jsonb_build_object('formatted_address','123 Fixture Street','detail_address','Door') END);
  rid:=(public.direct_order_public_submit_v3(sid,secret,gen_random_uuid(),payload)->>'request_id')::uuid;
  ASSERT (SELECT operating_release_id=release FROM public.direct_order_requests WHERE id=rid),'request version not frozen';
  quote:=public.direct_order_staff_quote_with_payment_mode(shop,rid,0,NULL,'customer_direct');
  UPDATE public.direct_order_requests SET state='awaiting_payment_review' WHERE id=rid;
  UPDATE public.direct_order_quotes SET status='locked' WHERE id=(quote->>'id')::uuid;
  INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path,metadata)
  VALUES(rid,shop,'customer','payment_proof','Fixture proof',shop::text||'/'||rid::text||'/'||gen_random_uuid()::text||'.jpg',jsonb_build_object('quote_id',quote->>'id','quote_version','1')) RETURNING id INTO proof;
  PERFORM public.direct_order_record_receipt(shop,rid,(quote->>'id')::uuid,proof,(quote->>'final_total')::numeric,'Fixture-'||rid::text);
  SELECT * INTO ticket FROM public.direct_delivery_fulfillment_tickets WHERE request_id=rid;
  SELECT ord.* INTO o FROM public.orders ord JOIN public.direct_order_financials f ON f.order_id=ord.id WHERE f.request_id=rid;
  SELECT s.id INTO s1 FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_id=o.id AND s.position=1;
  SELECT s.id INTO s2 FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_id=o.id AND s.position=2;
  ASSERT s1 IS NOT NULL AND s2 IS NOT NULL,'direct order steps missing';
  PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000001',true);
  PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'start',jsonb_build_array(jsonb_build_object('step_id',s1,'revision',0,'quantity',2)));
  ASSERT (SELECT status='preparing' AND accepted_at IS NOT NULL FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket.id),'first kitchen did not start ticket';
  PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'done',jsonb_build_array(jsonb_build_object('step_id',s1,'revision',1,'quantity',2)));
  ASSERT (SELECT cooking_completed_at IS NULL FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket.id),'intermediate kitchen completed ticket';
  PERFORM set_config('request.jwt.claim.sub',a2::text,true);
  PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'start',jsonb_build_array(jsonb_build_object('step_id',s2,'revision',0,'quantity',2)));
  PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'done',jsonb_build_array(jsonb_build_object('step_id',s2,'revision',1,'quantity',1)));
  ASSERT (SELECT cooking_completed_at IS NULL FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket.id),'partial final kitchen completed ticket';
  IF channel='delivery' THEN
   PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'undo_done',jsonb_build_array(jsonb_build_object('step_id',s2,'revision',2,'quantity',1)));
   ASSERT (SELECT cooking_completed_at IS NULL FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket.id);
   PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'done',jsonb_build_array(jsonb_build_object('step_id',s2,'revision',3,'quantity',1)));
  END IF;
  SELECT * INTO step FROM public.store_preparation_steps WHERE id=s2;
  PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'done',jsonb_build_array(jsonb_build_object('step_id',s2,'revision',step.revision,'quantity',1)));
  ASSERT (SELECT cooking_completed_at IS NOT NULL FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket.id),'final kitchen did not complete ticket';
  ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_floor_ready_lots WHERE order_id=o.id),'direct order notified table floor';
  UPDATE public.direct_delivery_fulfillment_tickets SET status='ready' WHERE id=ticket.id;
  SELECT * INTO step FROM public.store_preparation_steps WHERE id=s2;
  BEGIN PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'undo_done',jsonb_build_array(jsonb_build_object('step_id',s2,'revision',step.revision,'quantity',1))); RAISE EXCEPTION 'READY_TICKET_UNDONE'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_PROGRESS_CHANGED'; END;
 END LOOP;
END $$;
SELECT 'MULTI_KITCHEN_PICKUP_DELIVERY=PASS';
ROLLBACK;
