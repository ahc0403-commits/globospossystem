\set ON_ERROR_STOP on
BEGIN;
DO $$ DECLARE o uuid; work_row record; event_id uuid; financial_hash text;
BEGIN
 IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
 o:=hours_test.new_order();
 SELECT md5(jsonb_agg(to_jsonb(i) ORDER BY i.id)::text) INTO financial_hash
 FROM public.order_items i WHERE order_id=o;
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000002',true);
 FOR work_row IN SELECT id FROM public.emergency_fulfillment_items WHERE order_id=o LOOP
  event_id:=gen_random_uuid();
  PERFORM public.emergency_record_progress(work_row.id,'kitchen_done',1,event_id);
  PERFORM public.emergency_record_progress(work_row.id,'kitchen_done',1,event_id);
  PERFORM public.emergency_record_progress(work_row.id,'kitchen_done',-1,gen_random_uuid());
  PERFORM public.emergency_record_progress(work_row.id,'kitchen_done',1,gen_random_uuid());
 END LOOP;
 IF (SELECT count(*) FROM public.emergency_fulfillment_items WHERE order_id=o)<>6
 OR EXISTS(SELECT 1 FROM public.emergency_fulfillment_items WHERE order_id=o
   AND (kitchen_started_quantity<>1 OR kitchen_done_quantity<>1)) THEN
  RAISE EXCEPTION 'DELIVERY_INDIVIDUAL_KITCHEN_PROGRESS_FAILED'; END IF;
 UPDATE public.emergency_station_assignments SET station_type='tray';
 FOR work_row IN SELECT id FROM public.emergency_fulfillment_items WHERE order_id=o LOOP
  PERFORM public.emergency_record_progress(work_row.id,'tray_received',1,gen_random_uuid());
  PERFORM public.emergency_record_progress(work_row.id,'tray_dispatched',1,gen_random_uuid());
 END LOOP;
 IF EXISTS(SELECT 1 FROM public.emergency_fulfillment_items WHERE order_id=o AND tray_dispatched_quantity<>1)
 OR financial_hash IS DISTINCT FROM (SELECT md5(jsonb_agg(to_jsonb(i) ORDER BY i.id)::text)
   FROM public.order_items i WHERE order_id=o) THEN
  RAISE EXCEPTION 'DELIVERY_PROGRESS_CHANGED_FINANCIALS_OR_BLOCKED_TRAY'; END IF;
END $$;
ROLLBACK;
SELECT 'DELIVERY_INDIVIDUAL_KITCHEN_PROGRESS=PASS retry=PASS undo=PASS tray=PASS financials=PASS' AS result;
