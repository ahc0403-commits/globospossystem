\set ON_ERROR_STOP on
DO $$ BEGIN IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF; END $$;
SELECT set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',false);
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}',false);
DO $test$
DECLARE f jsonb; other jsonb; r uuid; shop uuid; q uuid; item_q uuid; iid uuid;
 old text; current text; n bigint; result jsonb; scope text; count_before integer; i integer; o uuid; queue uuid;
BEGIN
 f:=proof_test.scope(); r:=(f->>'request_id')::uuid; shop:=(f->>'store_id')::uuid;
 old:=public.direct_order_public_updates((f->>'session_id')::uuid,f->>'secret',r)->>'revision';
 SELECT chat_revision INTO n FROM public.direct_order_requests WHERE id=r;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body)
 SELECT r,shop,'cashier','text','chat automatic fixture' FROM generate_series(1,100);
 ASSERT (SELECT chat_revision=n+1 FROM public.direct_order_requests WHERE id=r),'BATCH_BUMP_WAS_NOT_SET_BASED';
 current:=public.direct_order_public_updates((f->>'session_id')::uuid,f->>'secret',r)->>'revision';
 ASSERT current<>old,'CHAT_INSERT_NOT_DETECTED'; old:=current;
 UPDATE public.direct_order_messages SET metadata=metadata||'{"translations":{"ko":"번역"}}'::jsonb
 WHERE request_id=r AND body='chat automatic fixture';
 current:=public.direct_order_public_updates((f->>'session_id')::uuid,f->>'secret',r)->>'revision';
 ASSERT current<>old,'CHAT_TRANSLATION_NOT_DETECTED'; old:=current;
 DELETE FROM public.direct_order_messages WHERE request_id=r AND body='chat automatic fixture';
 ASSERT (public.direct_order_public_updates((f->>'session_id')::uuid,f->>'secret',r)->>'revision')<>old,'CHAT_DELETE_NOT_DETECTED';
 result:=public.direct_order_public_updates((f->>'session_id')::uuid,f->>'secret',r);
 ASSERT (SELECT count(*)=1 FROM jsonb_object_keys(result)) AND result?'revision','CHAT_RESPONSE_EXPOSES_DATA';
 other:=proof_test.scope();
 BEGIN
  PERFORM public.direct_order_public_updates((other->>'session_id')::uuid,other->>'secret',r);
  RAISE EXCEPTION 'OTHER_CUSTOMER_CHAT_VISIBLE';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'DIRECT_ORDER_REQUEST_NOT_FOUND' THEN RAISE; END IF; END;
 UPDATE public.direct_order_requests SET customer_note='Private cashier fixture' WHERE id=r;
 SELECT id INTO q FROM public.direct_order_customer_requirements WHERE request_id=r AND source_kind='order';
 ASSERT q IS NOT NULL AND (SELECT print_scope='cashier' FROM public.direct_order_customer_requirements WHERE id=q),'PRIVATE_DEFAULT_LEAK';
 SELECT id INTO iid FROM public.direct_order_request_items WHERE request_id=r LIMIT 1;
 UPDATE public.direct_order_request_items SET item_note='Cooking fixture sauce separate' WHERE id=iid;
 SELECT id INTO item_q FROM public.direct_order_customer_requirements WHERE request_id=r AND source_kind='item';
 ASSERT item_q IS NOT NULL AND (SELECT print_scope='preparation' FROM public.direct_order_customer_requirements WHERE id=item_q),'COOKING_DEFAULT_MISSING';
 -- Real staff write: private Korean replies need no printable Vietnamese text.
 UPDATE public.direct_order_requests SET state='awaiting_quote' WHERE id=r;
 PERFORM public.direct_order_staff_reply_requirement(shop,r,q,1,gen_random_uuid(),'관리자에게만 보내는 답변','ko',false,'','','cashier');
 PERFORM public.direct_order_staff_reply_requirement(shop,r,item_q,1,gen_random_uuid(),'Sauce separate','en',false,'Cooking fixture','Cooking confirmed fixture','preparation');
 ASSERT public.direct_order_requirement_snapshot(r)::text LIKE '%Private cashier fixture%','ADMIN_LOST_PRIVATE_NOTE';
 FOREACH scope IN ARRAY ARRAY['preparation','delivery','receipt'] LOOP
  result:=public.direct_order_requirement_print_snapshot(r,scope);
  ASSERT result::text NOT LIKE '%Private cashier fixture%' AND result::text NOT LIKE '%관리자에게만%', 'PRIVATE_NOTE_EXPORTED';
  IF scope<>'delivery' THEN ASSERT result::text LIKE '%Cooking confirmed fixture%','COOKING_NOTE_DROPPED'; END IF;
 END LOOP;
 SELECT count(*) INTO count_before FROM public.direct_order_requirement_addenda WHERE requirement_id=q;
 PERFORM public.direct_order_emit_requirement_addendum(q);
 ASSERT (SELECT count(*)=count_before FROM public.direct_order_requirement_addenda WHERE requirement_id=q),'PRIVATE_NOTE_ADDENDUM';
 UPDATE public.direct_order_requests SET state='awaiting_payment_review' WHERE id=r;
 PERFORM public.direct_order_record_receipt(shop,r,(f->>'quote_id')::uuid,(f->>'proof_id')::uuid,108000,'CHAT-AUDIENCE-'||r::text);
 SELECT order_id INTO o FROM public.direct_order_financials WHERE request_id=r;
 queue:=gen_random_uuid();
 INSERT INTO public.emergency_order_queue(id,workflow_version,order_id) VALUES(queue,1,o);
 -- Kitchen and checker consume the same enriched page field.
 FOREACH scope IN ARRAY ARRAY['kitchen','tray'] LOOP
  result:=public.emergency_enrich_start_ready_orders(jsonb_build_array(jsonb_build_object(
   'queue_id',queue,'order_id',o,'station',scope,'items','[]'::jsonb)));
  ASSERT result->0->'direct_order_packing'->>'confirmed_notes' LIKE '%Cooking confirmed fixture%', 'KDS_COOKING_NOTE_MISSING';
  ASSERT result->0->'direct_order_packing'->>'confirmed_notes' NOT LIKE '%Private cashier fixture%', 'KDS_PRIVATE_NOTE_LEAK';
 END LOOP;
 SELECT value INTO result FROM jsonb_array_elements(public.direct_delivery_ticket_list_v3(shop,NULL,100))
 WHERE value->>'request_id'=r::text;
 ASSERT result->>'confirmed_notes' LIKE '%Cooking confirmed fixture%', 'DELIVERY_KITCHEN_COOKING_NOTE_MISSING';
 ASSERT result->>'confirmed_notes' NOT LIKE '%Private cashier fixture%', 'DELIVERY_KITCHEN_PRIVATE_NOTE_LEAK';
 -- A staff member can deliberately route a whole-order cooking request.
 PERFORM public.direct_order_staff_reply_requirement(shop,r,q,2,gen_random_uuid(),'Prepare less spicy','en',false,'Less spicy','Less spicy confirmed','preparation');
 ASSERT public.direct_order_requirement_print_snapshot(r,'preparation')::text LIKE '%Less spicy confirmed%','EXPLICIT_COOKING_SCOPE_IGNORED';
 UPDATE public.direct_order_requests SET customer_note='New private cashier fixture' WHERE id=r;
 ASSERT (SELECT print_scope='cashier' AND status='awaiting_reply' FROM public.direct_order_customer_requirements WHERE id=q),'SOURCE_EDIT_REUSED_OLD_SCOPE';
 f:=proof_test.scope(); r:=(f->>'request_id')::uuid;
 FOR i IN 1..60 LOOP
  PERFORM public.direct_order_public_updates((f->>'session_id')::uuid,f->>'secret',r);
 END LOOP;
 BEGIN
  PERFORM public.direct_order_public_updates((f->>'session_id')::uuid,f->>'secret',r);
  RAISE EXCEPTION 'CHAT_RATE_NOT_BOUNDED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'DIRECT_ORDER_CHAT_RATE_LIMITED' THEN RAISE; END IF; END;
 -- A second authenticated customer behind the same network has its own budget.
 PERFORM public.direct_order_public_updates((other->>'session_id')::uuid,other->>'secret',(other->>'request_id')::uuid);
 RAISE NOTICE 'CHAT_AUDIENCE=PASS batch_revision insert translation delete tiny_response ownership private_default cooking_default staff_private_reply print_routes addenda explicit_cooking source_edit';
END;
$test$;
