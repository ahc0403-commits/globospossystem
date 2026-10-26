\set ON_ERROR_STOP on
BEGIN;
CREATE OR REPLACE FUNCTION kds_test.assert(ok boolean,label text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION 'JGB_ASSERT:%',label; END IF; END $$;
SET LOCAL request.jwt.claim.sub='ba000000-0000-4000-8000-000000900022';
SELECT kds_test.assert(public.get_kds_sync_config()->>'bounded_sync_version'='3','capability');
SELECT kds_test.assert(public.get_kds_sync_config()->>'floor_label'='2F','stored floor preserved');
SELECT kds_test.assert(NOT has_function_privilege('anon','public.get_jeongabok_kds_tickets_v3(uuid[])','EXECUTE'),'anon excluded');
SELECT kds_test.assert(NOT has_function_privilege('authenticated','public.jeongabok_kds_tickets_core_v3(uuid[])','EXECUTE'),'core private');
DO $$ DECLARE ids uuid[]; result jsonb; b jsonb; old jsonb; n jsonb; q record; i integer; BEGIN
 SELECT array_agg(id) INTO ids FROM (SELECT id FROM emergency_order_queue ORDER BY queue_no DESC LIMIT 99)q;
 result:=public.get_jeongabok_kds_tickets_v3(ids||ids[1]);
 PERFORM kds_test.assert(jsonb_array_length(result->'tickets')=cardinality(ids),'deduplicate IDs');
 PERFORM kds_test.assert((result->>'revision')::integer=120,'revision snapshot');
 FOR q IN SELECT value FROM jsonb_array_elements(result->'tickets') LOOP
  IF q.value->'ticket'<>'null'::jsonb THEN
   PERFORM kds_test.assert(q.value->'ticket'->>'floor_label'='2F','floor isolation');
   PERFORM kds_test.assert((q.value->'ticket'->>'kitchen_direct_to_floor')::boolean,'no checker workflow');
   IF to_regprocedure('public.get_kds_ticket_v2(uuid)') IS NOT NULL THEN
    EXECUTE 'SELECT public.get_kds_ticket_v2($1)->''ticket''' INTO old USING (q.value->>'queue_id')::uuid;
    n:=q.value->'ticket';
    -- Ready sequence for the compatibility tray is additive. JSON object null
    -- removal and station timing formatting are normalized, values are not.
    old:=jsonb_strip_nulls(old)-'oldest_tray_ready_sequence';
    n:=jsonb_strip_nulls(n)-'oldest_tray_ready_sequence';
    old:=jsonb_set(old,'{items}',(SELECT jsonb_agg(jsonb_strip_nulls(x)-'oldest_tray_ready_sequence') FROM jsonb_array_elements(old->'items')x));
    n:=jsonb_set(n,'{items}',(SELECT jsonb_agg(jsonb_strip_nulls(x)-'oldest_tray_ready_sequence') FROM jsonb_array_elements(n->'items')x));
    IF old IS DISTINCT FROM n THEN RAISE EXCEPTION 'JGB_TICKET_PARITY: % old-only=% new-only=%',q.value->>'queue_id',old,n; END IF;
   END IF;
  END IF;
 END LOOP;
 b:=public.get_jeongabok_kds_bootstrap_v3();
 PERFORM kds_test.assert(b->'completed_orders'='[]'::jsonb,'history optional');
 PERFORM kds_test.assert(b->'snapshot'->>'restaurant_id'='273b057e-3b69-46e3-93c1-6194c2802849','bootstrap tenant');
 PERFORM kds_test.assert((b->'snapshot'->>'kitchen_direct_to_floor')::boolean,'bootstrap workflow');
 result:=public.get_jeongabok_kds_tickets_v3(ARRAY[kds_test.id(1),kds_test.id(200001)]);
 PERFORM kds_test.assert(NOT EXISTS(SELECT 1 FROM jsonb_array_elements(result->'tickets')x WHERE x->'ticket'<>'null'::jsonb),'missing and old day tombstones');
 BEGIN PERFORM public.get_jeongabok_kds_tickets_v3(array_fill(kds_test.id(1),ARRAY[101])); RAISE EXCEPTION 'accepted oversized batch'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'KDS_TICKET_BATCH_INVALID' THEN RAISE; END IF; END;
 BEGIN PERFORM public.get_jeongabok_kds_tickets_v3(ARRAY[NULL::uuid]); RAISE EXCEPTION 'accepted null'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'KDS_TICKET_BATCH_INVALID' THEN RAISE; END IF; END;
 BEGIN PERFORM public.get_jeongabok_kds_completed_page_v1(101); RAISE EXCEPTION 'accepted oversized history'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'KDS_HISTORY_PAGE_INVALID' THEN RAISE; END IF; END;
END $$;
-- Read-contract regressions with partial quantities, immutable choices,
-- floor readiness, canceled rows and delivery/pickup separation.
SET LOCAL session_replication_role=replica;
DO $$ DECLARE f record; t jsonb; b jsonb; BEGIN
 SELECT * INTO f FROM emergency_fulfillment_items WHERE queue_id=kds_test.id(200080) ORDER BY id LIMIT 1;
 UPDATE emergency_fulfillment_items SET ordered_quantity=2,source_quantity=2,kitchen_started_quantity=2,kitchen_done_quantity=1,
  tray_received_quantity=1,tray_dispatched_quantity=1,floor_served_quantity=0 WHERE id=f.id;
 UPDATE order_items SET menu_option_snapshot='{"name_ko":"고정 L 볶음밥","name_vi":"Frozen L rice","name_en":"Frozen L rice","size":"L","meal":"rice"}'::jsonb,is_takeout=true,notes='fixture note' WHERE id=f.order_item_id;
 INSERT INTO emergency_floor_ready_lots(id,restaurant_id,session_id,queue_id,order_id,order_item_id,source_kind,source_id,ready_action_id,ready_sequence,ready_quantity)
 VALUES(kds_test.id(700001),f.restaurant_id,f.session_id,f.queue_id,f.order_id,f.order_item_id,'base',f.id,kds_test.id(700002),5,1);
 t:=public.get_jeongabok_kds_tickets_v3(ARRAY[f.queue_id])->'tickets'->0->'ticket';
 SELECT value INTO b FROM jsonb_array_elements(t->'items') WHERE value->>'id'=f.id::text;
 PERFORM kds_test.assert(b->>'kitchen_started_quantity'='2' AND b->>'kitchen_done_quantity'='1' AND b->>'floor_served_quantity'='0','partial start/handoff/served distinct');
 PERFORM kds_test.assert(b->>'oldest_ready_sequence'='5','ready sequence');
 PERFORM kds_test.assert(b->>'name_vi'='Frozen L rice' AND b->'menu_option_snapshot'->>'meal'='rice','frozen language/size/meal');
 PERFORM kds_test.assert(b->>'is_takeout'='true' AND b->>'notes'='fixture note','takeout and notes');
 -- Cooking start alone does not invent a handed quantity or floor readiness.
 UPDATE emergency_fulfillment_items SET kitchen_done_quantity=0,tray_received_quantity=0,tray_dispatched_quantity=0 WHERE id=f.id;
 UPDATE emergency_floor_ready_lots SET voided_quantity=1 WHERE source_id=f.id;
 t:=public.get_jeongabok_kds_tickets_v3(ARRAY[f.queue_id])->'tickets'->0->'ticket';
 SELECT value INTO b FROM jsonb_array_elements(t->'items') WHERE value->>'id'=f.id::text;
 PERFORM kds_test.assert(b->>'kitchen_done_quantity'='0' AND NOT b?'oldest_ready_sequence','cooking start does not hand off');
 UPDATE emergency_fulfillment_items SET is_cancelled=true WHERE id=f.id;
 t:=public.get_jeongabok_kds_tickets_v3(ARRAY[f.queue_id])->'tickets'->0->'ticket';
 PERFORM kds_test.assert(NOT EXISTS(SELECT 1 FROM jsonb_array_elements(t->'items')x WHERE x->>'id'=f.id::text),'canceled line omitted');
 UPDATE orders SET sales_channel='delivery' WHERE id=f.order_id;
 PERFORM kds_test.assert(public.get_jeongabok_kds_tickets_v3(ARRAY[f.queue_id])->'tickets'->0->'ticket'='null'::jsonb,'delivery excluded from floor');
 UPDATE orders SET sales_channel='dine_in' WHERE id=f.order_id;
 INSERT INTO direct_order_requests(id,restaurant_id,session_id,client_request_id,reference_code,fulfillment_type,fulfillment_method)
 VALUES(kds_test.id(700010),f.restaurant_id,f.session_id,kds_test.id(700011),'D00000001','pickup','pickup');
 INSERT INTO direct_order_financials(request_id,restaurant_id,quote_id,order_id,payment_id,menu_total,service_charge_total,delivery_fee_total,final_total,approved_by)
 VALUES(kds_test.id(700010),f.restaurant_id,kds_test.id(700012),f.order_id,kds_test.id(700013),1,0,0,1,kds_test.id(900011));
 PERFORM kds_test.assert(public.get_jeongabok_kds_tickets_v3(ARRAY[f.queue_id])->'tickets'->0->'ticket'='null'::jsonb,'pickup excluded from floor');
 PERFORM kds_test.assert(NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.get_jeongabok_kds_completed_page_v1()->'orders')x WHERE x->>'queue_id'=f.queue_id::text),'pickup excluded before page limit');
END $$;
SET LOCAL request.jwt.claim.sub='ba000000-0000-4000-8000-000000900021';
DO $$ DECLARE t jsonb; i jsonb; q record; BEGIN
 t:=public.get_jeongabok_kds_tickets_v3(ARRAY[kds_test.id(200080)])->'tickets'->0->'ticket';
 PERFORM kds_test.assert(t->>'direct_fulfillment_type'='pickup' AND t->'direct_order_packing'->>'reference_code'='D00000001','kitchen pickup packing preserved');
 SELECT * INTO q FROM emergency_order_queue WHERE id=kds_test.id(200080);
 INSERT INTO emergency_floor_direct_items(id,session_id,restaurant_id,queue_id,order_id,order_item_id,line_key,source_kind,name_ko,name_vi,name_en,source_quantity,ordered_quantity,floor_served_quantity)
 SELECT kds_test.id(700020),q.session_id,q.restaurant_id,q.id,q.order_id,oi.id,'beverage','order_item','음료','Drink','Drink',2,2,1 FROM order_items oi WHERE oi.order_id=q.order_id ORDER BY oi.id LIMIT 1;
 t:=public.get_jeongabok_kds_tickets_v3(ARRAY[q.id])->'tickets'->0->'ticket';
 SELECT value INTO i FROM jsonb_array_elements(t->'items') WHERE value->>'id'=kds_test.id(700020)::text;
 PERFORM kds_test.assert(i->>'fulfillment_route'='floor_direct' AND i->>'floor_served_quantity'='1','direct beverage partial quantity');
 INSERT INTO emergency_fulfillment_sessions(id,restaurant_id,reason,status,closed_at,closed_by,close_resolution) VALUES(kds_test.id(700030),q.restaurant_id,'closed fixture','closed',now(),kds_test.id(900011),'digital_completed');
 UPDATE emergency_order_queue SET session_id=kds_test.id(700030) WHERE id=q.id;
 PERFORM kds_test.assert(public.get_jeongabok_kds_tickets_v3(ARRAY[q.id])->'tickets'->0->'ticket'='null'::jsonb,'closed session excluded');
END $$;
-- Other stores retain the exact config and cannot use JeonGabok readers.
SET LOCAL request.jwt.claim.sub='ba000000-0000-4000-8000-000000900024';
SELECT kds_test.assert(public.get_kds_sync_config()=public.get_kds_sync_config_pre_jeongabok(),'other store unchanged');
DO $$ BEGIN
 BEGIN PERFORM public.get_jeongabok_kds_tickets_v3(ARRAY[kds_test.id(200066)]); RAISE EXCEPTION 'cross tenant accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'JEONGABOK_KDS_SCOPE_REQUIRED' THEN RAISE; END IF; END;
END $$;
-- An inactive assignment cannot read even if it knows queue IDs.
SET LOCAL session_replication_role=replica;
UPDATE emergency_station_assignments SET is_active=false WHERE user_id=kds_test.id(900012);
SET LOCAL request.jwt.claim.sub='ba000000-0000-4000-8000-000000900022';
DO $$ BEGIN
 BEGIN PERFORM public.get_jeongabok_kds_tickets_v3(ARRAY[kds_test.id(200066)]); RAISE EXCEPTION 'inactive assignment accepted'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'JEONGABOK_KDS_SCOPE_REQUIRED' THEN RAISE; END IF; END;
END $$;
ROLLBACK;
SELECT 'JEONGABOK_KDS_BOUNDED_SCOPE_PARITY=PASS';
