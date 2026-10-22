\set ON_ERROR_STOP on
BEGIN;
SELECT set_config('request.jwt.claim.sub',test_uuid(101)::text,true);
DO $$DECLARE line uuid; ev uuid:=gen_random_uuid(); result jsonb; BEGIN
 line:=test_line(10,2,2,1,1);
 result:=kds_record_station_progress_v3(line,'base','floor_served',1,ev);
 ASSERT result->>'floor_served_quantity'='1',result::text;
 ASSERT result->>'kitchen_started_quantity'='2',result::text;
 ASSERT (SELECT sum(served_quantity)=1 FROM emergency_floor_ready_lots WHERE source_id=line);
 result:=kds_record_station_progress_v3(line,'base','floor_served',1,ev);
 ASSERT result->>'deduplicated'='true',result::text;
 ASSERT (SELECT count(*)=1 FROM emergency_fulfillment_events WHERE event_id=ev);
 BEGIN
  PERFORM kds_record_station_progress_v3(line,'base','floor_served',1,gen_random_uuid());
  RAISE EXCEPTION 'OVERSERVE_ALLOWED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='EMERGENCY_QUANTITY_CHAIN_VIOLATION',SQLERRM; END;
 PERFORM kds_record_station_progress_v3(line,'base','floor_served',-1,gen_random_uuid());
 ASSERT (SELECT floor_served_quantity=0 FROM emergency_fulfillment_items WHERE id=line);
 BEGIN
  PERFORM kds_record_station_progress_v3(line,'base','floor_served',-1,gen_random_uuid());
  RAISE EXCEPTION 'NEGATIVE_SERVICE_ALLOWED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='EMERGENCY_QUANTITY_CHAIN_VIOLATION',SQLERRM; END;
 RAISE NOTICE 'PASS partial floor, replay, over-service, undo boundaries';
END$$;
DO $$DECLARE line uuid; BEGIN
 UPDATE emergency_station_assignments SET station_type='tray',floor_label=NULL WHERE user_id=test_uuid(1);
 line:=test_line(11,2,2,1,0);
 PERFORM kds_record_station_progress_v3(line,'base','tray_dispatched',1,gen_random_uuid());
 ASSERT (SELECT kitchen_done_quantity=1 AND tray_dispatched_quantity=1 FROM emergency_fulfillment_items WHERE id=line);
 BEGIN
  PERFORM kds_record_station_progress_v3(line,'base','tray_dispatched',1,gen_random_uuid());
  RAISE EXCEPTION 'UNREADY_TRAY_HANDOFF_ALLOWED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='EMERGENCY_QUANTITY_CHAIN_VIOLATION',SQLERRM; END;
 PERFORM kds_record_station_progress_v3(line,'base','tray_dispatched',-1,gen_random_uuid());
 ASSERT (SELECT tray_dispatched_quantity=0 FROM emergency_fulfillment_items WHERE id=line);
 UPDATE emergency_station_assignments SET station_type='floor',floor_label='1F' WHERE user_id=test_uuid(1);
 line:=test_line(12,2,2,1,1,false,'3F');
 BEGIN
  PERFORM kds_record_station_progress_v3(line,'base','floor_served',1,gen_random_uuid());
  RAISE EXCEPTION 'CROSS_FLOOR_ALLOWED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='EMERGENCY_STAGE_FORBIDDEN',SQLERRM; END;
 BEGIN
  PERFORM kds_serve_ready_order_v3(test_uuid(20012),gen_random_uuid());
  RAISE EXCEPTION 'CROSS_FLOOR_BULK_ALLOWED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='EMERGENCY_QUEUE_UNAVAILABLE',SQLERRM; END;
 line:=test_line(13,2,2,1,1,false,'2F');
 PERFORM kds_record_station_progress_v3(line,'base','floor_served',1,gen_random_uuid());
 PERFORM set_config('request.jwt.claim.sub',test_uuid(103)::text,true);
 BEGIN
  PERFORM kds_record_station_progress_v3(test_uuid(10),'base','floor_served',1,gen_random_uuid());
  RAISE EXCEPTION 'CROSS_STORE_ALLOWED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='EMERGENCY_ITEM_UNAVAILABLE',SQLERRM; END;
 PERFORM set_config('request.jwt.claim.sub',test_uuid(101)::text,true);
 RAISE NOTICE 'PASS partial tray, undo, unready prevention, shared floor and store boundaries';
END$$;
DO $$DECLARE line uuid; result jsonb; BEGIN
 PERFORM set_config('request.jwt.claim.sub',test_uuid(102)::text,true);
 UPDATE emergency_station_assignments SET station_type='kitchen',floor_label=NULL WHERE user_id=test_uuid(2);
 line:=test_line(20,2,0,0,0,true);
 PERFORM kds_record_station_progress_v3(line,'base','kitchen_started',1,gen_random_uuid());
 PERFORM kds_record_station_progress_v3(line,'base','kitchen_started',1,gen_random_uuid());
 ASSERT (SELECT kitchen_started_quantity=2 AND kitchen_done_quantity=0 FROM emergency_fulfillment_items WHERE id=line);
 ASSERT NOT EXISTS(SELECT 1 FROM emergency_floor_ready_lots WHERE source_id=line);
 PERFORM kds_apply_station_progress_batch_v1(gen_random_uuid(),'273b057e-3b69-46e3-93c1-6194c2802849',test_uuid(2),
 'kitchen_done',NULL,jsonb_build_array(jsonb_build_object('item_id',line,'queue_id',test_uuid(20020),'source_kind','base','quantity',1)));
 UPDATE emergency_station_assignments SET station_type='floor',floor_label='1F' WHERE user_id=test_uuid(2);
 result:=kds_record_station_progress_v3(line,'base','floor_served',1,gen_random_uuid());
 ASSERT result->>'kitchen_started_quantity'='2' AND result->>'kitchen_done_quantity'='1'
  AND result->>'floor_served_quantity'='1',result::text;
 ASSERT NOT EXISTS(SELECT 1 FROM emergency_tray_ready_lots WHERE source_id=line);
 RAISE NOTICE 'PASS JeonGabok preparation remains distinct from partial handoff and customer service';
END$$;
SELECT set_config('request.jwt.claim.sub',test_uuid(101)::text,true);
DO $$DECLARE parent uuid; component uuid:=test_uuid(31); result jsonb; BEGIN
 parent:=test_line(30,2,2,1,1);
 INSERT INTO emergency_combo_component_items SELECT component,restaurant_id,session_id,queue_id,order_id,
 order_item_id,ordered_quantity,excused_quantity,kitchen_started_quantity,kitchen_done_quantity,
 tray_received_quantity,tray_dispatched_quantity,floor_served_quantity,is_cancelled,needs_review,updated_at
 FROM emergency_fulfillment_items WHERE id=parent;
 UPDATE emergency_floor_ready_lots SET source_kind='combo_component',source_id=component WHERE source_id=parent;
 result:=kds_record_station_progress_v3(component,'combo_component','floor_served',1,gen_random_uuid());
 ASSERT result->>'floor_served_quantity'='1',result::text;
 ASSERT (SELECT kitchen_started_quantity=2 AND kitchen_done_quantity=1 AND floor_served_quantity=1
 FROM emergency_fulfillment_items WHERE id=parent);
 RAISE NOTICE 'PASS partial combo and commercial parent projection';
END$$;
DO $$DECLARE line uuid; ev uuid:=gen_random_uuid(); result jsonb; BEGIN
 line:=test_line(40,3,3,1,1,false,'2F');
 INSERT INTO emergency_floor_direct_items VALUES(test_uuid(41),test_uuid(20040),0);
 result:=kds_serve_ready_order_v3(test_uuid(20040),ev);
 ASSERT result->>'changed_quantity'='1',result::text;
 ASSERT (SELECT kitchen_started_quantity=3 AND kitchen_done_quantity=1 AND floor_served_quantity=1
 FROM emergency_fulfillment_items WHERE id=line);
 ASSERT (SELECT floor_served_quantity=0 FROM emergency_floor_direct_items WHERE id=test_uuid(41));
 ASSERT (SELECT floor_label='2F' FROM emergency_fulfillment_actions WHERE action_id=ev);
 ASSERT (SELECT count(*)=1 AND sum(delta)=1 FROM emergency_fulfillment_events WHERE details->>'batch_request_id'=ev::text);
 result:=kds_serve_ready_order_v3(test_uuid(20040),ev);
 ASSERT result->>'deduplicated'='true',result::text;
 result:=kds_serve_ready_order_v3(test_uuid(20040),gen_random_uuid());
 ASSERT result->>'changed_quantity'='0',result::text;
 RAISE NOTICE 'PASS bulk serves only ready food, retains drinks and unprepared remainder, records actual area';
END$$;
DO $$DECLARE parent uuid; request uuid:=gen_random_uuid(); result jsonb; BEGIN
 parent:=test_line(50,2,2,1,1);
 INSERT INTO emergency_combo_component_items
 SELECT test_uuid(component.n),restaurant_id,session_id,queue_id,order_id,order_item_id,
 ordered_quantity,excused_quantity,kitchen_started_quantity,kitchen_done_quantity,
 tray_received_quantity,tray_dispatched_quantity,floor_served_quantity,is_cancelled,needs_review,updated_at
 FROM emergency_fulfillment_items,generate_series(51,52)component(n) WHERE id=parent;
 DELETE FROM emergency_floor_ready_lots WHERE source_id=parent;
 INSERT INTO emergency_floor_ready_lots(restaurant_id,session_id,queue_id,order_id,order_item_id,
 source_kind,source_id,ready_sequence,ready_quantity)
 SELECT restaurant_id,session_id,queue_id,order_id,order_item_id,'combo_component',id,1,1
 FROM emergency_combo_component_items WHERE queue_id=test_uuid(20050);
 result:=kds_serve_ready_order_v3(test_uuid(20050),request);
 ASSERT result->>'changed_quantity'='2',result::text;
 ASSERT (SELECT floor_served_quantity=1 AND kitchen_done_quantity=1
 FROM emergency_fulfillment_items WHERE id=parent);
 ASSERT (SELECT count(*)=2 AND sum(delta)=2 FROM emergency_fulfillment_events
 WHERE details->>'batch_request_id'=request::text);
 parent:=test_line(60,2,2,1,1);
 DELETE FROM emergency_floor_ready_lots WHERE source_id=parent;
 request:=gen_random_uuid();
 BEGIN
  PERFORM kds_serve_ready_order_v3(test_uuid(20060),request);
  RAISE EXCEPTION 'MISSING_READY_LOT_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='KDS_BATCH_STALE',SQLERRM; END;
 ASSERT (SELECT floor_served_quantity=0 FROM emergency_fulfillment_items WHERE id=parent);
 ASSERT NOT EXISTS(SELECT 1 FROM emergency_fulfillment_actions WHERE action_id=request);
 ASSERT NOT EXISTS(SELECT 1 FROM emergency_fulfillment_events WHERE details->>'batch_request_id'=request::text);
 parent:=test_line(61,2,2,1,1);
 UPDATE orders SET sales_channel='delivery' WHERE id=test_uuid(10061);
 BEGIN
  PERFORM kds_record_station_progress_v3(parent,'base','floor_served',1,gen_random_uuid());
  RAISE EXCEPTION 'DELIVERY_TABLE_FLOOR_SERVE_ALLOWED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='KDS_WORKFLOW_VERSION_UNAVAILABLE',SQLERRM; END;
 UPDATE emergency_fulfillment_items SET needs_review=true WHERE id=parent;
 BEGIN
  PERFORM kds_record_station_progress_v3(parent,'base','floor_served',1,gen_random_uuid());
  RAISE EXCEPTION 'REVIEW_BLOCKED_ITEM_ALLOWED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='EMERGENCY_ITEM_UNAVAILABLE',SQLERRM; END;
 RAISE NOTICE 'PASS bulk combo projection, missing-lot atomic rollback, delivery and review exclusions';
END$$;
-- 1/100/1000 units in one row and up to 1000 selected rows. This executes the
-- actual mutation kernel; it measures server time, not Docker/client startup.
DO $$DECLARE n int; count_lines int; line uuid; request uuid; result jsonb; started timestamptz; elapsed numeric;
BEGIN
 FOREACH n IN ARRAY ARRAY[1,100,1000] LOOP
  line:=test_line(100+n,n,n,n,n);
  started:=clock_timestamp();
  result:=kds_serve_ready_order_v3(test_uuid(20100+n),gen_random_uuid());
  elapsed:=extract(epoch FROM clock_timestamp()-started)*1000;
  ASSERT result->>'changed_quantity'=n::text,result::text;
  ASSERT (SELECT count(*)=1 AND sum(delta)=n FROM emergency_fulfillment_events WHERE order_item_id=test_uuid(30100+n));
  ASSERT elapsed<2000,elapsed::text;
  RAISE NOTICE 'MEASURE bulk lines=1 units=% elapsed_ms=% response_bytes=% audit_events=1',n,round(elapsed,3),octet_length(result::text);
 END LOOP;
 line:=test_line(5000,1,1,1,1);
 INSERT INTO emergency_fulfillment_items
 SELECT test_uuid(5000+series.seq),restaurant_id,session_id,queue_id,order_id,test_uuid(40000+series.seq),
 1,0,1,1,1,1,0,false,false,now() FROM emergency_fulfillment_items,generate_series(1,999)series(seq) WHERE id=line;
 INSERT INTO emergency_floor_ready_lots(restaurant_id,session_id,queue_id,order_id,order_item_id,source_kind,source_id,ready_sequence,ready_quantity)
 SELECT restaurant_id,session_id,queue_id,order_id,order_item_id,'base',id,1,1
 FROM emergency_fulfillment_items WHERE queue_id=test_uuid(25000) AND id<>line;
 request:=gen_random_uuid(); started:=clock_timestamp();
 result:=kds_serve_ready_order_v3(test_uuid(25000),request);
 elapsed:=extract(epoch FROM clock_timestamp()-started)*1000;
 ASSERT result->>'changed_quantity'='1000',result::text;
 ASSERT (SELECT count(*)=1000 AND sum(delta)=1000 FROM emergency_fulfillment_events WHERE details->>'batch_request_id'=request::text);
 ASSERT elapsed<2000,elapsed::text;
 RAISE NOTICE 'MEASURE bulk lines=1000 units=1000 elapsed_ms=% response_bytes=% audit_events=1000',round(elapsed,3),octet_length(result::text);
 line:=test_line(7000,1001,1001,1001,1001);
 BEGIN
  PERFORM kds_serve_ready_order_v3(test_uuid(27000),gen_random_uuid());
  RAISE EXCEPTION 'OVERSIZED_BATCH_ALLOWED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='KDS_BATCH_INPUT_INVALID',SQLERRM; END;
 ASSERT (SELECT floor_served_quantity=0 FROM emergency_fulfillment_items WHERE id=line);
 RAISE NOTICE 'PASS 1000-row/unit limits and atomic oversized rejection';
END$$;
ROLLBACK;
