DO $progress$
DECLARE f jsonb; r uuid; shop uuid; sid uuid; secret text; v jsonb; o uuid; n integer;
BEGIN
 f:=photo_test.create_request(true,'store_prepaid');r:=(f->>'request_id')::uuid;shop:=(f->>'store_id')::uuid;
 UPDATE public.users SET restaurant_id=shop WHERE auth_id=auth.uid();
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=r;
 SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
 UPDATE public.direct_order_requests SET diner_count=3,utensils_requested=false WHERE id=r;
 v:=public.direct_order_public_status_v8(sid,secret,r);
 IF (v->'delivery'->>'utensils_requested')::boolean IS DISTINCT FROM false OR (v->'delivery'->>'diner_count')::integer<>3 THEN RAISE EXCEPTION 'UTENSILS_CUSTOMER_LOST'; END IF;
 IF v->'delivery'->>'cooking_complete'<>'false' THEN RAISE EXCEPTION 'NO_KDS_FALSE_COMPLETION'; END IF;
 v:=public.direct_order_staff_detail_v3(shop,r);
 IF v->'delivery'->>'utensils_requested'<>'false' THEN RAISE EXCEPTION 'UTENSILS_STAFF_LOST'; END IF;
 IF public.direct_order_public_status_v3(sid,secret,r)->'delivery' ? 'utensils_requested' THEN RAISE EXCEPTION 'LEGACY_STATUS_CHANGED'; END IF;
 FOR n IN SELECT unnest(ARRAY[1,10,50]) LOOP
  v:=public.direct_order_public_orders_v4(sid,secret,n);
  IF jsonb_array_length(v)>n OR NOT (v->0 ? 'quote_id') THEN RAISE EXCEPTION 'BATCH_SUMMARY_INVALID'; END IF;
  IF v->0->>'has_dispatch'<>'false' THEN RAISE EXCEPTION 'UNCONFIRMED_HANDOFF'; END IF;
  v:=public.direct_order_public_orders_v2(sid,secret,n);
  IF v->0 ? 'quote_id' OR v->0 ? 'cooking_complete' OR v->0 ? 'has_dispatch' THEN RAISE EXCEPTION 'LEGACY_LIST_CHANGED'; END IF;
 END LOOP;
 PERFORM photo_test.approve(f);
 SELECT order_id INTO o FROM public.direct_order_financials WHERE request_id=r;
 INSERT INTO public.emergency_fulfillment_items(order_id,is_cancelled,ordered_quantity,kitchen_done_quantity,tray_dispatched_quantity)
 VALUES(o,false,2,1,0),(o,false,1,1,0),(o,true,99,0,0);
 IF (SELECT cooking_complete FROM public.direct_order_cooking_progress(ARRAY[r])) THEN RAISE EXCEPTION 'PARTIAL_KDS_FALSE_COMPLETION'; END IF;
 UPDATE public.emergency_fulfillment_items SET kitchen_done_quantity=ordered_quantity WHERE order_id=o AND NOT is_cancelled;
 INSERT INTO public.emergency_fulfillment_events VALUES(o,'kitchen_done',1),(o,'kitchen_done',1);
 IF (SELECT count(*) FROM public.direct_order_customer_events WHERE request_id=r AND event_kind='cooking_complete')<>1 THEN RAISE EXCEPTION 'COOK_NOTICE_DUPLICATED'; END IF;
 v:=public.direct_order_public_status_v8(sid,secret,r);
 IF v->'delivery'->>'cooking_complete'<>'true' THEN RAISE EXCEPTION 'COOK_STATE_LOST'; END IF;
 UPDATE public.direct_delivery_fulfillment_tickets SET status='ready' WHERE request_id=r;
 UPDATE public.direct_delivery_fulfillment_tickets SET status='ready' WHERE request_id=r;
 IF (SELECT count(*) FROM public.direct_order_messages WHERE request_id=r AND body='DIRECT_ORDER_PACKING_COMPLETE')<>1 THEN RAISE EXCEPTION 'PACK_NOTICE_DUPLICATED'; END IF;
 v:=public.direct_order_receipt_packing_context(shop,o);
 IF v->>'utensils_requested'<>'false' THEN RAISE EXCEPTION 'UTENSILS_RECEIPT_LOST'; END IF;
 IF strpos(pg_get_functiondef('public.direct_order_staff_list_before_reconciliation(uuid,text[],integer,text)'::regprocedure),'LATERAL')>0 THEN RAISE EXCEPTION 'STAFF_LATERAL_REMAINS'; END IF;
 IF has_function_privilege('anon','public.direct_order_cooking_progress(uuid[])','EXECUTE') THEN RAISE EXCEPTION 'PROGRESS_ACCESS_LEAK'; END IF;
END; $progress$;
SELECT 'DIRECT_ORDER_CUSTOMER_PROGRESS=PASS';
DO $utensils$
DECLARE shop uuid:='d1000000-0000-4000-8000-000000000002'; sid uuid; client uuid; r uuid; payload jsonb; result jsonb; f jsonb; o uuid; amount numeric; count_before integer; queue uuid;
BEGIN
 UPDATE public.users SET restaurant_id=shop WHERE auth_id=auth.uid();
 INSERT INTO public.direct_order_sessions(restaurant_id,secret_hash,locale) VALUES(shop,repeat('c',64),'vi') RETURNING id INTO sid;
 payload:=jsonb_build_object('locale','vi','diner_count',3,'utensils_requested',false,'items',jsonb_build_array(jsonb_build_object('menu_item_id','d1000000-0000-4000-8000-000000000003','quantity',1)),
 'address',jsonb_build_object('customer_name','Fixture','customer_phone','0901234567','formatted_address','123 Fixture','detail_address','Door 1','address_source','manual','location_verified',false));
 client:=gen_random_uuid();result:=public.direct_order_public_submit_v3(sid,repeat('c',64),client,payload);r:=(result->>'request_id')::uuid;
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_requests WHERE id=r AND diner_count=3 AND NOT utensils_requested) THEN RAISE EXCEPTION 'SUBMIT_UTENSILS_LOST'; END IF;
 result:=public.direct_order_public_submit_v3(sid,repeat('c',64),client,jsonb_set(payload,'{utensils_requested}','true'));
 IF (SELECT utensils_requested FROM public.direct_order_requests WHERE id=r) THEN RAISE EXCEPTION 'REPLAY_CHANGED_UTENSILS'; END IF;
 PERFORM public.direct_order_staff_set_diner_count(shop,r,1,5);
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_requests WHERE id=r AND diner_count=5 AND NOT utensils_requested) THEN RAISE EXCEPTION 'DINER_EDIT_RESET_UTENSILS'; END IF;
 UPDATE public.direct_order_requests SET state='cancelled' WHERE id=r;
 BEGIN
  PERFORM public.direct_order_public_submit_v3(sid,repeat('c',64),gen_random_uuid(),jsonb_set(payload,'{utensils_requested}','null'));
  RAISE EXCEPTION 'INVALID_UTENSILS_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_UTENSILS_INVALID' THEN RAISE; END IF; END;
 result:=public.direct_order_public_submit_v3(sid,repeat('c',64),gen_random_uuid(),payload-'utensils_requested');
 IF NOT (SELECT utensils_requested FROM public.direct_order_requests WHERE id=(result->>'request_id')::uuid) THEN RAISE EXCEPTION 'LEGACY_UTENSILS_DEFAULT_CHANGED'; END IF;
 -- Immutable print snapshots reflect the choice at creation; new jobs use edits.
 f:=photo_test.create_request(true,'store_prepaid');r:=(f->>'request_id')::uuid;
 UPDATE public.direct_order_requests SET diner_count=3,utensils_requested=false WHERE id=r;
 PERFORM photo_test.approve(f); SELECT order_id INTO o FROM public.direct_order_financials WHERE request_id=r;
 IF NOT EXISTS(SELECT 1 FROM public.print_jobs pj WHERE pj.order_id=o AND pj.payload->>'utensils_requested'='false' AND pj.payload->>'diner_count'='3') THEN RAISE EXCEPTION 'PRINT_UTENSILS_LOST'; END IF;
 INSERT INTO public.digital_receipts(restaurant_id,order_id,snapshot) VALUES(shop,o,jsonb_build_object('items','[]'::jsonb)) ON CONFLICT DO NOTHING;
 IF NOT EXISTS(SELECT 1 FROM public.digital_receipts WHERE order_id=o AND snapshot->>'utensils_requested'='false' AND snapshot->>'diner_count'='3') THEN RAISE EXCEPTION 'DIGITAL_UTENSILS_LOST'; END IF;
 UPDATE public.direct_order_requests SET diner_count=5 WHERE id=r;
 IF EXISTS(SELECT 1 FROM public.print_jobs pj WHERE pj.order_id=o AND pj.payload->>'diner_count'<>'3') THEN RAISE EXCEPTION 'OLD_PRINT_SNAPSHOT_CHANGED'; END IF;
 -- Combo components and quantity changes cannot prematurely claim all food ready.
 INSERT INTO public.emergency_fulfillment_items(order_id,is_cancelled,ordered_quantity,kitchen_done_quantity,tray_dispatched_quantity) VALUES(o,false,1,1,0);
 INSERT INTO public.emergency_combo_component_items(id,order_id,ordered_quantity,kitchen_done_quantity,is_cancelled,needs_review) VALUES(gen_random_uuid(),o,2,1,false,false);
 IF (SELECT cooking_complete FROM public.direct_order_cooking_progress(ARRAY[r])) THEN RAISE EXCEPTION 'PARTIAL_COMBO_FALSE_COMPLETION'; END IF;
 UPDATE public.emergency_combo_component_items SET kitchen_done_quantity=2 WHERE order_id=o;
 IF NOT (SELECT cooking_complete FROM public.direct_order_cooking_progress(ARRAY[r])) THEN RAISE EXCEPTION 'COMPLETE_COMBO_LOST'; END IF;
 UPDATE public.emergency_combo_component_items SET needs_review=true WHERE order_id=o;
 IF (SELECT cooking_complete FROM public.direct_order_cooking_progress(ARRAY[r])) THEN RAISE EXCEPTION 'REVIEW_COMBO_FALSE_COMPLETION'; END IF;
 queue:=gen_random_uuid();
 INSERT INTO public.emergency_order_queue(id,workflow_version,order_id) VALUES(queue,1,o);
 result:=public.emergency_enrich_start_ready_orders(jsonb_build_array(jsonb_build_object('queue_id',queue,'order_id',o,'items','[]'::jsonb)));
 IF result->0->'direct_order_packing'->>'utensils_requested'<>'false' OR result->0->'direct_order_packing'->>'diner_count'<>'5' THEN RAISE EXCEPTION 'KDS_PACKING_CHOICE_LOST'; END IF;
 -- Terminal fulfillment retains unsettled customer money and evidence access.
 f:=photo_test.create_request(true,'store_prepaid');r:=(f->>'request_id')::uuid;
 PERFORM public.direct_order_record_receipt(shop,r,(f->>'quote_id')::uuid,(f->>'proof_id')::uuid,120000,'PROGRESS-EXCESS');
 UPDATE public.direct_order_requests SET delivery_fee_finalized=true WHERE id=r;
 UPDATE public.direct_delivery_fulfillment_tickets SET status='completed' WHERE request_id=r;
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=r;
 result:=public.direct_order_public_status_v8(sid,(SELECT secret_hash FROM public.direct_order_sessions WHERE id=sid),r);
 IF result->'support'->>'access_open'<>'true' THEN RAISE EXCEPTION 'COMPLETED_REFUND_ACCESS_CLOSED'; END IF;
END; $utensils$;
SELECT 'DIRECT_ORDER_UTENSILS_REPLAY_PRINT_AND_SUPPORT=PASS';

-- Explain the actual RPC body, not just an opaque SELECT function(...).
CREATE SCHEMA progress_measurement;
CREATE TABLE progress_measurement.session_scope(session_id uuid,secret_hash text,store_id uuid);
DO $plan$
DECLARE sid uuid; secret text; shop uuid; sql text; definition text; plan jsonb; n integer; rows integer;
BEGIN
 SELECT r.session_id,s.secret_hash,r.restaurant_id INTO sid,secret,shop
 FROM public.direct_order_requests r JOIN public.direct_order_sessions s ON s.id=r.session_id
 WHERE r.utensils_requested=false LIMIT 1;
 INSERT INTO progress_measurement.session_scope VALUES(sid,secret,shop);
 INSERT INTO public.direct_order_requests(restaurant_id,session_id,client_request_id,reference_code,state,locale)
 SELECT shop,sid,gen_random_uuid(),'D'||upper(left(replace(gen_random_uuid()::text,'-',''),8)),'awaiting_quote','vi'
 FROM generate_series(1,50);
 definition:=pg_get_functiondef('public.direct_order_public_orders_v4(uuid,text,integer)'::regprocedure);
 sql:=split_part(split_part(definition,'RETURN (',2),'  );',1);
 sql:=replace(replace(replace(sql,'s.restaurant_id',quote_literal(shop)||'::uuid'),'s.id',quote_literal(sid)||'::uuid'),
  's.created_at',quote_literal((SELECT created_at FROM public.direct_order_sessions WHERE id=sid))||'::timestamptz');
 FOR n IN SELECT unnest(ARRAY[1,10,50]) LOOP
  rows:=jsonb_array_length(public.direct_order_public_orders_v4(sid,secret,n));
  IF rows<>n THEN RAISE EXCEPTION 'MEASUREMENT_PAGE_INCOMPLETE'; END IF;
  EXECUTE 'EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) '||replace(sql,'p_limit',n::text) INTO plan;
  IF jsonb_path_exists(plan,'$[0].Plan.** ? (@."Parent Relationship" == "SubPlan")') THEN RAISE EXCEPTION 'CUSTOMER_CORRELATED_SUBPLAN %',plan; END IF;
  IF jsonb_path_exists(plan,'$[0].Plan.** ? (@."Function Name" == "direct_order_cooking_progress" && @."Actual Loops" > 1)') THEN RAISE EXCEPTION 'CUSTOMER_PROGRESS_N_PLUS_ONE'; END IF;
  RAISE NOTICE 'CUSTOMER_BATCH_PLAN=PASS orders=% rows=% correlated_subplans=0',n,rows;
 END LOOP;
END; $plan$;

CREATE TABLE progress_measurement.kitchen_batches(size integer,request_id uuid,allocations jsonb);
DO $batches$
DECLARE f jsonb; r uuid; o uuid; n integer; allocations jsonb;
BEGIN
 FOR n IN SELECT unnest(ARRAY[1,10,50]) LOOP
  f:=photo_test.create_request(true,'store_prepaid');r:=(f->>'request_id')::uuid;
  UPDATE public.users SET restaurant_id=(f->>'store_id')::uuid WHERE auth_id=auth.uid();
  PERFORM photo_test.approve(f);SELECT order_id INTO o FROM public.direct_order_financials WHERE request_id=r;
  WITH items AS (
   INSERT INTO public.emergency_fulfillment_items(order_id,is_cancelled,ordered_quantity,kitchen_done_quantity,tray_dispatched_quantity)
   SELECT o,false,1,0,0 FROM generate_series(1,n) RETURNING id
  ) SELECT jsonb_agg(jsonb_build_object('item_id',id,'source_kind','base','quantity',1)) INTO allocations FROM items;
  INSERT INTO progress_measurement.kitchen_batches VALUES(n,r,allocations);
 END LOOP;
 IF has_function_privilege('authenticated','public.kds_complete_kitchen_batch_before_customer_progress(uuid,jsonb)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_progress_notice_batch(uuid[],text)','EXECUTE') THEN RAISE EXCEPTION 'PROGRESS_INTERNAL_ACCESS_LEAK'; END IF;
END; $batches$;
