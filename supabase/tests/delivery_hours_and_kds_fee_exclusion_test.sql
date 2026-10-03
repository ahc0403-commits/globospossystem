\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN
 IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
END $$;
-- Deterministic clock is installed only in this disposable database.
CREATE FUNCTION hours_test.now() RETURNS timestamptz LANGUAGE sql AS $$
 SELECT ('2026-10-03 '||COALESCE(NULLIF(current_setting('direct_order.test_local_time',true),''),'12:00')||'+07')::timestamptz
$$;
DO $$ DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_is_within_hours(time,time,timestamptz)'::regprocedure) INTO d;
 EXECUTE replace(d,'DEFAULT now()','DEFAULT hours_test.now()');
END $$;
DO $$
DECLARE o uuid; f jsonb; r jsonb; s uuid; secret text; p jsonb; t text; e text; n integer; snapshot jsonb; item record;
 v_store uuid := 'd1000000-0000-4000-8000-000000000002';
BEGIN
 IF public.direct_order_is_within_hours('11:00','22:00','2026-10-03 10:59:59+07')
 OR NOT public.direct_order_is_within_hours('11:00','22:00','2026-10-03 11:00:00+07')
 OR NOT public.direct_order_is_within_hours('11:00','22:00','2026-10-03 21:59:59+07')
 OR public.direct_order_is_within_hours('11:00','22:00','2026-10-03 22:00:00+07')
 OR public.direct_order_is_within_hours('11:00','22:00','2026-10-03 23:59:59+07')
 OR public.direct_order_is_within_hours('11:00','22:00','2026-10-04 00:00:00+07')
 OR NOT public.direct_order_is_within_hours('11:00','22:00','2026-10-03 04:00:00+00') THEN
 RAISE EXCEPTION 'VIETNAM_HOURS_BOUNDARY_FAILED'; END IF;

 SELECT order_id INTO o FROM hours_test.legacy_order;
 IF (SELECT count(*) FROM public.emergency_fulfillment_items WHERE order_id=o AND NOT is_cancelled)<>6
 OR (SELECT md5(jsonb_agg(to_jsonb(i) ORDER BY id)::text) FROM public.order_items i WHERE order_id=o)
 IS DISTINCT FROM (SELECT financial_hash FROM hours_test.legacy_order) THEN
 RAISE EXCEPTION 'LEGACY_FEE_EXCLUSION_CHANGED_FINANCIAL_DATA'; END IF;
 o:=hours_test.new_order();
 IF (SELECT count(*) FROM public.emergency_fulfillment_items WHERE order_id=o)<>6 THEN
 RAISE EXCEPTION 'NEW_FEE_CREATED_WORK_LEDGER'; END IF;
 UPDATE public.order_items SET quantity=2 WHERE order_id=o AND item_type='service_charge';
 IF (SELECT count(*) FROM public.emergency_fulfillment_items WHERE order_id=o)<>6 THEN
 RAISE EXCEPTION 'FEE_UPDATE_CREATED_WORK_LEDGER'; END IF;

 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
 snapshot:=public.get_emergency_station_snapshot();
 SELECT count(*) INTO n FROM jsonb_array_elements(snapshot->'orders') ord,
 LATERAL jsonb_array_elements(ord->'items') i WHERE ord->>'order_id'=o::text;
 IF n<>6 OR snapshot::text LIKE '%Phí giao hàng%' THEN RAISE EXCEPTION 'STATION_SNAPSHOT_INCLUDES_FEE'; END IF;
 FOR item IN SELECT id FROM public.emergency_fulfillment_items WHERE order_id=o AND NOT is_cancelled LOOP
 PERFORM public.emergency_record_progress(item.id,'kitchen_done',1,gen_random_uuid()); END LOOP;
 UPDATE public.emergency_station_assignments SET station_type='tray';
 FOR item IN SELECT id FROM public.emergency_fulfillment_items WHERE order_id=o AND NOT is_cancelled LOOP
 PERFORM public.emergency_record_progress(item.id,'tray_received',1,gen_random_uuid());
 PERFORM public.emergency_record_progress(item.id,'tray_dispatched',1,gen_random_uuid()); END LOOP;
 IF EXISTS(SELECT 1 FROM public.emergency_fulfillment_items WHERE order_id=o AND NOT is_cancelled AND tray_dispatched_quantity<ordered_quantity) THEN
 RAISE EXCEPTION 'FEES_BLOCK_TRAY_COMPLETION'; END IF;
 snapshot:=public.get_emergency_station_snapshot();
 IF snapshot::text LIKE '%Phí giao hàng%' THEN RAISE EXCEPTION 'TRAY_SNAPSHOT_INCLUDES_FEE'; END IF;

 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
 secret:=repeat('a',64);
 INSERT INTO public.direct_order_sessions(restaurant_id,secret_hash,locale) VALUES(v_store,secret,'vi') RETURNING id INTO s;
 p:=jsonb_build_object('locale','vi','items',jsonb_build_array(jsonb_build_object('menu_item_id','d1000000-0000-4000-8000-000000000003','quantity',1)),
 'address',jsonb_build_object('customer_name','Hours test','customer_phone','0900000000','formatted_address','Test address','detail_address','Test detail','address_source','manual','location_verified',false));
 FOREACH t IN ARRAY ARRAY['10:59:59','11:00:00','21:30:00','21:59:59','22:00:00','00:00:00'] LOOP
  PERFORM set_config('direct_order.test_local_time',t,true);
  e:=NULL;
  BEGIN r:=public.direct_order_public_submit(s,secret,gen_random_uuid(),p); EXCEPTION WHEN OTHERS THEN e:=SQLERRM; END;
  IF t IN ('10:59:59','22:00:00','00:00:00') THEN
   IF e IS DISTINCT FROM 'DIRECT_ORDER_OUTSIDE_HOURS' THEN RAISE EXCEPTION 'OUTSIDE_HOURS_NOT_BLOCKED:%:%',t,e; END IF;
  ELSIF e IS NOT NULL THEN RAISE EXCEPTION 'OPEN_HOURS_NOT_ACCEPTED:%:%',t,e;
  ELSE UPDATE public.direct_order_requests SET state='rejected' WHERE id=(r->>'request_id')::uuid;
  END IF;
  IF (public.direct_order_public_storefront('photo-test')->>'paused')::boolean IS DISTINCT FROM (t IN ('10:59:59','22:00:00','00:00:00'))
   OR (public.direct_order_staff_get_availability_v2(v_store)->>'hours_open')::boolean IS DISTINCT FROM (t NOT IN ('10:59:59','22:00:00','00:00:00')) THEN
   RAISE EXCEPTION 'PUBLIC_AND_STAFF_HOURS_DISAGREE:%',t; END IF;
 END LOOP;
 -- An accepted request remains idempotent when retried outside the window.
 PERFORM set_config('direct_order.test_local_time','12:00',true);
 r:=public.direct_order_public_submit(s,secret,'a1000000-0000-4000-8000-000000000001',p);
 PERFORM set_config('direct_order.test_local_time','22:00',true);
 IF NOT (public.direct_order_public_submit(s,secret,'a1000000-0000-4000-8000-000000000001',p)->>'idempotent')::boolean THEN
 RAISE EXCEPTION 'CLOSURE_BROKE_ACCEPTED_REQUEST_RETRY'; END IF;
 -- The reduced payment fixture retains the historical isolated POS-print gate.
 UPDATE public.restaurant_settings SET fulfillment_mode='pos_print';
 UPDATE public.emergency_fulfillment_sessions SET status='closed';
 f:=photo_test.create_request(); PERFORM photo_test.approve(f);
 PERFORM photo_test.assert_single_graph((f->>'request_id')::uuid);
 PERFORM set_config('direct_order.test_local_time','12:00',true);
 PERFORM public.direct_order_staff_set_paused(v_store,true);
 e:=NULL;
 BEGIN PERFORM public.direct_order_public_submit(s,secret,gen_random_uuid(),p); EXCEPTION WHEN OTHERS THEN e:=SQLERRM; END;
 IF e IS DISTINCT FROM 'DIRECT_ORDER_STOREFRONT_PAUSED' THEN RAISE EXCEPTION 'MANUAL_PAUSE_IGNORED:%',e; END IF;
 f:=photo_test.create_request();
 UPDATE public.direct_order_requests SET state='awaiting_quote' WHERE id=(f->>'request_id')::uuid;
 UPDATE public.direct_order_quotes SET status='superseded' WHERE id=(f->>'quote_id')::uuid;
 PERFORM public.direct_order_staff_quote(v_store,(f->>'request_id')::uuid,0,NULL);
 f:=photo_test.create_request(); PERFORM photo_test.approve(f);
 PERFORM photo_test.assert_single_graph((f->>'request_id')::uuid);
 PERFORM set_config('direct_order.test_local_time','22:00',true);
 r:=public.direct_order_staff_set_paused(v_store,false);
 IF NOT (r->>'paused')::boolean THEN RAISE EXCEPTION 'MANUAL_OPEN_BYPASSED_SCHEDULE'; END IF;
 IF (SELECT count(*) FROM jsonb_object_keys(r))<>4 THEN RAISE EXCEPTION 'LEGACY_STAFF_RESPONSE_CHANGED'; END IF;
END $$;
ROLLBACK;
SELECT 'HOURS_BOUNDARIES_SERVER_REJECTION_KITCHEN_TRAY_FINANCIAL_PRESERVATION=PASS' AS result;
