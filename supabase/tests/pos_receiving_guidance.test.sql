BEGIN;
DO $test$
DECLARE result jsonb;po uuid;before_lines jsonb;after_lines jsonb;started timestamptz;line_count integer;
BEGIN
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 DELETE FROM public.procurement_role_roster WHERE restaurant_id=test_uuid(101) AND system='pos' AND subject_id=test_uuid(1) AND stage='requester';
 result:=public.get_inventory_order_catalog(test_uuid(101));
 ASSERT result->'actor'->>'role'='inventory_orderer';
 ASSERT (result->'actor'->>'receiving_only')::boolean,'Receiver entry is explicit';
 INSERT INTO public.procurement_role_roster(restaurant_id,system,subject_id,stage,display_name,valid_from,valid_until,reason,assigned_by,account_kind)
 VALUES(test_uuid(101),'pos',test_uuid(1),'requester','Fixture requester',now()-interval '1 day',now()+interval '1 day','Operations test','{}','shared_role')
 ON CONFLICT(restaurant_id,system,subject_id,stage) DO UPDATE SET valid_from=EXCLUDED.valid_from,valid_until=EXCLUDED.valid_until;
 result:=public.get_inventory_order_catalog(test_uuid(101));
 ASSERT NOT (result->'actor'->>'receiving_only')::boolean,'PR account keeps its request entry';
 SELECT p.id INTO po FROM public.inventory_purchase_orders p WHERE restaurant_id=test_uuid(101)
 AND EXISTS(SELECT 1 FROM public.inventory_purchase_order_lines l WHERE l.purchase_order_id=p.id) LIMIT 1;
 ASSERT po IS NOT NULL;
 result:=public.get_inventory_workflow_detail_before_receiving_guidance(po);
 before_lines:=result->'lines';
 started:=clock_timestamp();
 result:=public.get_inventory_workflow_detail(po);
 after_lines:=result->'lines';
 ASSERT jsonb_array_length(after_lines)>0;
 ASSERT jsonb_array_length(after_lines)=jsonb_array_length(before_lines),'No line multiplication';
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(after_lines) line
   WHERE NOT(line ? 'current_stock_base') OR NOT(line ? 'stock_base_unit'));
 ASSERT (SELECT count(*) FROM jsonb_array_elements(after_lines))=(SELECT count(DISTINCT line->>'id') FROM jsonb_array_elements(after_lines) line),'Unique original lines';
 RAISE NOTICE 'POS_RECEIVING_GUIDANCE=PASS lines=% detail_rpc_calls=1 bytes=% db_ms=%',jsonb_array_length(after_lines),octet_length(result::text),extract(epoch FROM clock_timestamp()-started)*1000;
 FOR line_count IN SELECT unnest(ARRAY[1,20,200]) LOOP
  started:=clock_timestamp();
  result:=public.get_inventory_workflow_detail(test_uuid(140000+line_count));
  ASSERT jsonb_array_length(result->'lines')=line_count,'Bounded selected-order response';
  ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(result->'lines') line WHERE line->>'current_stock_base' IS NULL),'Stock enrichment must have actual fixture data';
  RAISE NOTICE 'POS_RECEIVING_DETAIL_MEASURE lines=% rpc_calls=1 bytes=% db_ms=%',line_count,octet_length(result::text),extract(epoch FROM clock_timestamp()-started)*1000;
 END LOOP;
END $test$;
ROLLBACK;
