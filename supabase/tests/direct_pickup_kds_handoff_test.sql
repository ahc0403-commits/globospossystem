\set ON_ERROR_STOP on
BEGIN;
INSERT INTO public.kds_realtime_rollouts(restaurant_id,mode)
VALUES('d1000000-0000-4000-8000-000000000002','active');
-- Synthetic devices exercise push routing only in this disposable database.
INSERT INTO public.emergency_web_push_devices
SELECT gen_random_uuid(),id,restaurant_id,true,'fixture-token' FROM public.emergency_station_assignments;
DO $$
#variable_conflict use_column
DECLARE f jsonb; approval jsonb; result jsonb; snapshot jsonb; o uuid; q uuid;
 item_id uuid; request_id uuid; ticket_id uuid; ticket_version integer; before_hash text; event_id uuid;
BEGIN
 IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
 SELECT request,approval,financial_hash INTO f,approval,before_hash FROM pickup_kds_test.stranded;
 o:=(approval->>'order_id')::uuid; request_id:=(f->>'request_id')::uuid;
 result:=public.enqueue_direct_pickup_kds((f->>'store_id')::uuid,request_id);
 q:=(result->>'queue_id')::uuid;
 ASSERT result->>'status'='queued' AND (result->>'added_lines')::integer=1;
 ASSERT (SELECT workflow_version=1 AND table_number=(SELECT reference_code FROM public.direct_order_requests WHERE id=request_id)
  FROM public.emergency_order_queue WHERE id=q);
 ASSERT (SELECT count(*)=1 FROM public.emergency_fulfillment_items WHERE order_id=o);
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_fulfillment_items i JOIN public.order_items oi ON oi.id=i.order_item_id
  WHERE i.order_id=o AND (oi.item_type='service_charge' OR i.kitchen_done_quantity<>0 OR i.tray_dispatched_quantity<>0));
 result:=public.enqueue_direct_pickup_kds((f->>'store_id')::uuid,request_id);
 ASSERT (result->>'added_lines')::integer=0;
 ASSERT (SELECT count(*)=1 FROM public.audit_logs WHERE entity_id=request_id AND action='direct_order_pickup_kds_queued');
 ASSERT (SELECT count(*)=1 FROM public.emergency_push_deliveries WHERE order_id=o AND station_type='kitchen');
 ASSERT NOT EXISTS(SELECT 1 FROM public.kds_change_log WHERE order_id=o AND 'floor'=ANY(target_stations));
 ASSERT before_hash=pickup_kds_test.financial_hash(o);

 SELECT id,version INTO ticket_id,ticket_version FROM public.direct_delivery_fulfillment_tickets WHERE request_id=(f->>'request_id')::uuid;
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
 BEGIN
  PERFORM public.direct_order_cashier_complete_pickup((f->>'store_id')::uuid,request_id,ticket_version);
  RAISE EXCEPTION 'CASHIER_COMPLETED_UNREADY_PICKUP';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'DIRECT_ORDER_PICKUP_NOT_READY' THEN RAISE; END IF; END;
 BEGIN
  PERFORM public.direct_delivery_ticket_transition((f->>'store_id')::uuid,ticket_id,ticket_version,'preparing');
  RAISE EXCEPTION 'DEDICATED_BOARD_BYPASSED_KDS';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'DIRECT_ORDER_PICKUP_USE_KDS' THEN RAISE; END IF; END;
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.direct_delivery_ticket_list(
  (f->>'store_id')::uuid,ARRAY['pending','preparing','ready'],NULL,NULL,100)) x WHERE x->>'ticket_id'=ticket_id::text);

 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
 snapshot:=public.get_emergency_station_snapshot();
 snapshot:=public.emergency_add_order_sales_channels(snapshot->'orders','kitchen');
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(snapshot) x WHERE x->>'order_id'=o::text
  AND x->>'direct_fulfillment_type'='pickup' AND x->>'sales_channel'='takeaway'
  AND (x->'items'->0->>'is_takeout')::boolean);
 SELECT id INTO item_id FROM public.emergency_fulfillment_items WHERE order_id=o;
 event_id:=gen_random_uuid();
 PERFORM public.emergency_record_progress(item_id,'kitchen_done',1,event_id);
 PERFORM public.emergency_record_progress(item_id,'kitchen_done',1,event_id);
 ASSERT (SELECT status='preparing' FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket_id);
 ASSERT (SELECT kitchen_done_quantity=1 AND kitchen_started_quantity=1 FROM public.emergency_fulfillment_items WHERE id=item_id);
 ASSERT (SELECT count(*)=1 FROM public.emergency_push_deliveries WHERE order_id=o AND station_type='tray');

 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000003',true);
 snapshot:=public.get_emergency_station_snapshot();
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(snapshot->'orders') x WHERE x->>'order_id'=o::text);
 PERFORM public.emergency_record_progress(item_id,'tray_received',1,gen_random_uuid());
 ASSERT (SELECT status='preparing' FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket_id);
 PERFORM public.emergency_record_progress(item_id,'tray_dispatched',1,gen_random_uuid());
 ASSERT (SELECT status='ready' AND dispatched_at IS NULL FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket_id);
 PERFORM public.emergency_record_progress(item_id,'tray_dispatched',-1,gen_random_uuid());
 ASSERT (SELECT status='preparing' AND ready_at IS NULL FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket_id);
 PERFORM public.emergency_record_progress(item_id,'tray_dispatched',1,gen_random_uuid());
 ASSERT (SELECT status='ready' FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket_id);
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_push_deliveries WHERE order_id=o AND station_type='floor');
 ASSERT NOT EXISTS(SELECT 1 FROM public.kds_change_log WHERE order_id=o AND 'floor'=ANY(target_stations));

 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000004',true);
 ASSERT public.get_kds_ticket_v2(q)->'ticket'='null'::jsonb;
 ASSERT public.emergency_add_order_sales_channels(jsonb_build_array(jsonb_build_object('order_id',o,'items','[]'::jsonb)),'floor')='[]'::jsonb;
 BEGIN
  PERFORM public.emergency_record_progress(item_id,'floor_served',1,gen_random_uuid());
  RAISE EXCEPTION 'PICKUP_REACHED_FLOOR';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'DIRECT_ORDER_PICKUP_FLOOR_FORBIDDEN' THEN RAISE; END IF; END;
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
 SELECT version INTO ticket_version FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket_id;
 result:=public.direct_order_cashier_complete_pickup((f->>'store_id')::uuid,request_id,ticket_version);
 ASSERT result->>'status'='completed';
 result:=public.direct_order_cashier_complete_pickup((f->>'store_id')::uuid,request_id,ticket_version);
 ASSERT (result->>'idempotent')::boolean;
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000003',true);
 BEGIN
  PERFORM public.emergency_record_progress(item_id,'tray_dispatched',-1,gen_random_uuid());
  RAISE EXCEPTION 'COMPLETED_PICKUP_WAS_REOPENED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'DIRECT_ORDER_PICKUP_HANDOFF_FINALIZED' THEN RAISE; END IF; END;
 ASSERT before_hash=pickup_kds_test.financial_hash(o);
END $$;
-- Future approvals enqueue atomically, retries do not duplicate financial/KDS graphs.
DO $$
#variable_conflict use_column
DECLARE f jsonb; approval jsonb; o uuid; h text;
BEGIN
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
 f:=photo_test.create_request(true,'not_applicable','pickup');
 approval:=photo_test.approve(f); o:=(approval->>'order_id')::uuid;
 h:=pickup_kds_test.financial_hash(o);
 ASSERT (SELECT count(*)=1 FROM public.emergency_order_queue WHERE order_id=o);
 ASSERT (SELECT count(*)=1 FROM public.emergency_fulfillment_items WHERE order_id=o);
 PERFORM photo_test.approve(f);
 ASSERT h=pickup_kds_test.financial_hash(o);
 ASSERT (SELECT count(*)=1 FROM public.emergency_fulfillment_items WHERE order_id=o);
 -- A missing active session aborts the entire approval, including payment/stock.
 f:=photo_test.create_request(true,'not_applicable','pickup');
 UPDATE public.emergency_fulfillment_sessions SET status='completed';
 BEGIN
  PERFORM photo_test.approve(f);
  RAISE EXCEPTION 'PAPERLESS_PICKUP_APPROVED_WITHOUT_SESSION';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'DIRECT_ORDER_PICKUP_KDS_SESSION_REQUIRED' THEN RAISE; END IF; END;
 PERFORM photo_test.assert_empty_graph((f->>'request_id')::uuid);
 UPDATE public.emergency_fulfillment_sessions SET status='active';
 -- Print stores retain the dedicated pickup board and do not enter KDS.
 UPDATE public.restaurant_settings SET fulfillment_mode='pos_print';
 f:=photo_test.create_request(true,'not_applicable','pickup');
 approval:=photo_test.approve(f); o:=(approval->>'order_id')::uuid;
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_order_queue WHERE order_id=o);
 ASSERT (SELECT status='pending' FROM public.direct_delivery_fulfillment_tickets WHERE request_id=(f->>'request_id')::uuid);
 UPDATE public.restaurant_settings SET fulfillment_mode='paperless';
 -- Delivery continues to enter the ordinary KDS and finish as dispatched.
 f:=photo_test.create_request(); approval:=photo_test.approve(f); o:=(approval->>'order_id')::uuid;
 ASSERT (SELECT count(*)=1 FROM public.emergency_order_queue WHERE order_id=o);
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
 PERFORM public.emergency_record_progress((SELECT id FROM public.emergency_fulfillment_items WHERE order_id=o),'kitchen_done',1,gen_random_uuid());
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000003',true);
 PERFORM public.emergency_record_progress((SELECT id FROM public.emergency_fulfillment_items WHERE order_id=o),'tray_received',1,gen_random_uuid());
 PERFORM public.emergency_record_progress((SELECT id FROM public.emergency_fulfillment_items WHERE order_id=o),'tray_dispatched',1,gen_random_uuid());
 ASSERT (SELECT status='dispatched' FROM public.direct_delivery_fulfillment_tickets WHERE request_id=(f->>'request_id')::uuid);
END $$;
-- Whole-order buttons use the same ownership and readiness rules.
DO $$ DECLARE f jsonb; approval jsonb; q uuid; o uuid; a uuid; result jsonb;
BEGIN
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
 f:=photo_test.create_request(true,'not_applicable','pickup');
 approval:=photo_test.approve(f); o:=(approval->>'order_id')::uuid;
 SELECT id INTO q FROM public.emergency_order_queue WHERE order_id=o;
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000004',true);
 BEGIN
  PERFORM public.emergency_complete_order_stage(q,gen_random_uuid());
  RAISE EXCEPTION 'BULK_PICKUP_REACHED_FLOOR';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'DIRECT_ORDER_PICKUP_FLOOR_FORBIDDEN' THEN RAISE; END IF; END;
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
 PERFORM public.emergency_complete_order_stage(q,gen_random_uuid());
 ASSERT (SELECT status='preparing' FROM public.direct_delivery_fulfillment_tickets WHERE request_id=(f->>'request_id')::uuid);
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000003',true);
 a:=gen_random_uuid(); PERFORM public.emergency_complete_order_stage(q,a);
 ASSERT (SELECT status='ready' FROM public.direct_delivery_fulfillment_tickets WHERE request_id=(f->>'request_id')::uuid);
 PERFORM public.emergency_revert_order_action(q,a,gen_random_uuid());
 ASSERT (SELECT status='preparing' FROM public.direct_delivery_fulfillment_tickets WHERE request_id=(f->>'request_id')::uuid);
 PERFORM public.emergency_complete_order_stage(q,gen_random_uuid());
 ASSERT (SELECT status='ready' FROM public.direct_delivery_fulfillment_tickets WHERE request_id=(f->>'request_id')::uuid);
 ASSERT NOT EXISTS(SELECT 1 FROM public.kds_change_log WHERE order_id=o AND 'floor'=ANY(target_stations));
END $$;
ROLLBACK;
SELECT 'DIRECT_PICKUP_KDS_HANDOFF=PASS recovery=PASS retry=PASS finance=PASS roles=PASS undo=PASS approval=PASS delivery=PASS print=PASS' AS result;
