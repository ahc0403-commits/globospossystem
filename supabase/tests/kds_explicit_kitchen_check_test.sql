\set ON_ERROR_STOP on
BEGIN;
INSERT INTO users VALUES(test_uuid(4),test_uuid(104),'273b057e-3b69-46e3-93c1-6194c2802849',true);
INSERT INTO emergency_station_assignments(id,user_id,restaurant_id,station_type,floor_label)
 VALUES(test_uuid(4),test_uuid(4),'273b057e-3b69-46e3-93c1-6194c2802849','floor','1F');
INSERT INTO emergency_web_push_devices VALUES(test_uuid(500),'273b057e-3b69-46e3-93c1-6194c2802849',test_uuid(4),'isolated-fixture-device',true);
-- Both workflows exercise the same real single-item RPC as the explicit UI
-- check. Preparation alone must not make food ready for the next station.
DO $$
DECLARE direct boolean; source text; parent uuid; line uuid; event uuid;
 result jsonb; n integer:=700; actor integer; done_quantity integer;
BEGIN
 FOREACH direct IN ARRAY ARRAY[false,true] LOOP
  FOREACH source IN ARRAY ARRAY['base','combo_component'] LOOP
   n:=n+1; actor:=CASE WHEN direct THEN 2 ELSE 1 END;
   PERFORM set_config('request.jwt.claim.sub',test_uuid(actor+100)::text,true);
   UPDATE emergency_station_assignments SET station_type='kitchen',floor_label=NULL WHERE user_id=test_uuid(actor);
   parent:=test_line(n,2,CASE WHEN direct THEN 2 ELSE 0 END,0,0,direct);
   line:=parent;
   IF source='combo_component' THEN
    line:=test_uuid(n+1000);
    INSERT INTO emergency_combo_component_items SELECT line,restaurant_id,session_id,queue_id,order_id,
     order_item_id,ordered_quantity,excused_quantity,kitchen_started_quantity,kitchen_done_quantity,
     tray_received_quantity,tray_dispatched_quantity,floor_served_quantity,is_cancelled,needs_review,updated_at
    FROM emergency_fulfillment_items WHERE id=parent;
   END IF;
   event:=gen_random_uuid();
   result:=kds_record_station_progress_v3(line,source,'kitchen_done',1,event);
   ASSERT result->>'kitchen_done_quantity'='1',result::text;
   ASSERT result->>'floor_served_quantity'='0',result::text;
   result:=kds_record_station_progress_v3(line,source,'kitchen_done',1,event);
   ASSERT result->>'deduplicated'='true',result::text;
   IF direct THEN
    ASSERT (SELECT sum(ready_quantity-served_quantity-voided_quantity)=1
      FROM emergency_floor_ready_lots WHERE source_id=line AND source_kind=source);
    ASSERT NOT EXISTS(SELECT 1 FROM emergency_tray_ready_lots WHERE source_id=line);
    ASSERT EXISTS(SELECT 1 FROM emergency_push_deliveries push JOIN emergency_fulfillment_events audit
     ON audit.event_id=push.event_id WHERE audit.order_id=test_uuid(n+10000) AND push.station_type='floor'), 'missing floor notification';
    ASSERT (SELECT count(*)=1 FROM emergency_push_deliveries push JOIN emergency_fulfillment_events audit
     ON audit.event_id=push.event_id WHERE audit.order_id=test_uuid(n+10000)), 'duplicate floor push';
   ELSE
    ASSERT (SELECT sum(ready_quantity-handed_quantity-voided_quantity)=1
      FROM emergency_tray_ready_lots WHERE source_id=line AND source_kind=source);
    ASSERT NOT EXISTS(SELECT 1 FROM emergency_floor_ready_lots WHERE source_id=line);
    ASSERT EXISTS(SELECT 1 FROM emergency_station_push_log push JOIN emergency_fulfillment_events audit
     ON audit.event_id=push.event_id WHERE audit.order_id=test_uuid(n+10000) AND push.station_type='tray'), 'missing tray notification';
   END IF;
   RAISE NOTICE 'EXPLICIT_KITCHEN_CHECK direct=% source=% partial_quantity=1 duplicate=deduplicated',direct,source;
  END LOOP;
 END LOOP;
 -- The new explicit check retains the existing FIFO guard. A rejected later
 -- ticket must not mutate quantities or publish a ready lot.
 PERFORM set_config('request.jwt.claim.sub',test_uuid(102)::text,true);
 parent:=test_line(710,2,2,0,0,true);
 line:=test_line(711,2,2,0,0,true);
 UPDATE order_items SET menu_item_id=test_uuid(40710),label='fixture menu 710',display_name='fixture menu 710' WHERE id=test_uuid(30711);
 BEGIN
  PERFORM kds_record_station_progress_v3(line,'base','kitchen_done',1,gen_random_uuid());
  RAISE EXCEPTION 'FIFO_GUARD_BYPASSED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='KDS_CHECKET_SELECTION_STALE',SQLERRM; END;
 ASSERT NOT EXISTS(SELECT 1 FROM emergency_floor_ready_lots WHERE source_id=line);
 PERFORM kds_record_station_progress_v3(parent,'base','kitchen_done',1,gen_random_uuid());
 PERFORM kds_record_station_progress_v3(parent,'base','kitchen_done',1,gen_random_uuid());
 result:=kds_record_station_progress_v3(line,'base','kitchen_done',1,gen_random_uuid());
 ASSERT result->>'kitchen_done_quantity'='1',result::text;
 RAISE NOTICE 'EXPLICIT_KITCHEN_FIFO earlier_ticket_guard=PASS no_false_floor_readiness=PASS';
END$$;
ROLLBACK;
