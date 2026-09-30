SET request.jwt.claim.role='service_role';
CREATE FUNCTION public.expect_stock_audit_error(query text,expected text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
 BEGIN EXECUTE query; EXCEPTION WHEN OTHERS THEN IF position(expected in SQLERRM)>0 THEN RETURN; END IF; RAISE; END;
 RAISE EXCEPTION 'Expected error: %',expected;
END $$;
DO $$ DECLARE session jsonb; draft jsonb; lines jsonb; single_line jsonb; sid uuid; item_id uuid; old_stock numeric; before_tx integer; result jsonb;
BEGIN
 session:=public.prepare_inventory_stock_audit('8bc9eef5-dcd5-46b1-b931-23f77132322c');
 sid:=(session->>'id')::uuid;
 IF jsonb_array_length(session->'snapshot')<>104 THEN RAISE EXCEPTION 'SNAPSHOT_TRUNCATED'; END IF;
 SELECT jsonb_agg(jsonb_build_object('product_id',x->>'product_id','actual_quantity_base',0,'counted_at',now()::text,'excluded_reason',null,'memo',null)) INTO lines FROM jsonb_array_elements(session->'snapshot') x;
 single_line:=jsonb_build_array(lines->0);
 item_id:=(session->'snapshot'->0->>'inventory_item_id')::uuid;
 SELECT current_stock INTO old_stock FROM public.inventory_items WHERE id=item_id;
 SELECT count(*) INTO before_tx FROM public.inventory_transactions;
 draft:=public.save_inventory_stock_audit_v2('8bc9eef5-dcd5-46b1-b931-23f77132322c',sid,1,single_line,false,'count');
 IF draft->>'status'<>'in_progress' OR (draft->>'version')::int<>2 OR (SELECT current_stock FROM public.inventory_items WHERE id=item_id)<>old_stock OR (SELECT count(*) FROM public.inventory_transactions)<>before_tx THEN RAISE EXCEPTION 'DRAFT_CHANGED_STOCK'; END IF;
 PERFORM public.expect_stock_audit_error(format('SELECT public.save_inventory_stock_audit_v2(%L,%L,1,%L,false)',session->>'store_id',sid,lines),'VERSION_CHANGED');
 PERFORM public.expect_stock_audit_error(format('SELECT public.save_inventory_stock_audit_v2(%L,%L,2,%L,true)',session->>'store_id',sid,single_line),'INCOMPLETE');
 PERFORM public.expect_stock_audit_error(format('SELECT public.save_inventory_stock_audit_v2(%L,%L,2,%L,false)',session->>'store_id',sid,single_line||single_line),'DUPLICATE_PRODUCT');
 PERFORM public.expect_stock_audit_error(format('SELECT public.save_inventory_stock_audit_v2(%L,%L,2,%L,false)',session->>'store_id',sid,jsonb_set(single_line,'{0,actual_quantity_base}','-1')),'ACTUAL_INVALID');
 PERFORM public.expect_stock_audit_error(format('SELECT public.save_inventory_stock_audit_v2(%L,%L,2,%L,false)',session->>'store_id',sid,jsonb_set(single_line,'{0,actual_quantity_base}','0.0001')),'ACTUAL_INVALID');
 PERFORM public.expect_stock_audit_error(format('SELECT public.save_inventory_stock_audit_v2(%L,%L,2,%L,false)',session->>'store_id',sid,jsonb_set(single_line,'{0,counted_at}',to_jsonb('2000-01-01T00:00:00Z'::text))),'COUNT_TIME_INVALID');
 PERFORM public.expect_stock_audit_error(format('SELECT public.save_inventory_stock_audit_v2(%L,%L,2,%L,false)','3a268807-771f-4fd4-84fe-e1b0b00de40a',sid,single_line),'SESSION_NOT_FOUND');
 -- Snapshot changes cannot be hidden by returning stock to its old value.
 UPDATE public.inventory_items SET updated_at=now()+interval '1 second' WHERE id=item_id;
 PERFORM public.expect_stock_audit_error(format('SELECT public.save_inventory_stock_audit_v2(%L,%L,2,%L,true)',session->>'store_id',sid,lines),'STOCK_CHANGED');
 UPDATE public.inventory_items SET updated_at=(session->'snapshot'->0->>'stock_updated_at')::timestamptz WHERE id=item_id;
 result:=public.save_inventory_stock_audit_v2('8bc9eef5-dcd5-46b1-b931-23f77132322c',sid,2,lines,true,'count');
 IF result->>'status'<>'completed' OR EXISTS(SELECT 1 FROM public.inventory_items WHERE restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c' AND current_stock<>0) OR (SELECT count(*) FROM public.inventory_transactions)<>before_tx+104 THEN RAISE EXCEPTION 'COMPLETE_FAILED'; END IF;
 -- Same retry returns the completed result and never duplicates adjustments.
 result:=public.save_inventory_stock_audit_v2('8bc9eef5-dcd5-46b1-b931-23f77132322c',sid,2,lines,true,'count');
 IF (SELECT count(*) FROM public.inventory_transactions)<>before_tx+104 THEN RAISE EXCEPTION 'RETRY_DUPLICATED_STOCK'; END IF;
 PERFORM public.expect_stock_audit_error(format('SELECT public.save_inventory_stock_audit_v2(%L,%L,2,%L,true)',session->>'store_id',sid,jsonb_set(lines,'{0,actual_quantity_base}','1')),'SESSION_NOT_EDITABLE');
 session:=public.prepare_inventory_stock_audit('8bc9eef5-dcd5-46b1-b931-23f77132322c');
 IF (session->>'id')::uuid=sid THEN RAISE EXCEPTION 'COMPLETED_SESSION_REUSED'; END IF;
 -- Explicit skipped rows can close a full audit without stock adjustments.
 SELECT jsonb_agg(jsonb_build_object('product_id',x->>'product_id','actual_quantity_base',null,'excluded_reason','not counted today')) INTO lines FROM jsonb_array_elements(session->'snapshot') x;
 result:=public.save_inventory_stock_audit_v2('8bc9eef5-dcd5-46b1-b931-23f77132322c',(session->>'id')::uuid,1,lines,true);
 IF (SELECT count(*) FROM public.inventory_transactions)<>before_tx+104 THEN RAISE EXCEPTION 'EXCLUSION_CHANGED_STOCK'; END IF;
 session:=public.prepare_inventory_stock_audit('8bc9eef5-dcd5-46b1-b931-23f77132322c');
 PERFORM public.cancel_inventory_stock_audit('8bc9eef5-dcd5-46b1-b931-23f77132322c',(session->>'id')::uuid,1);
 result:=public.prepare_inventory_stock_audit('8bc9eef5-dcd5-46b1-b931-23f77132322c');
 IF session->>'id'=result->>'id' THEN RAISE EXCEPTION 'CANCELLED_SESSION_REUSED'; END IF;
END $$;
SET request.jwt.claim.role='authenticated';
SELECT public.expect_stock_audit_error($q$SELECT public.prepare_inventory_stock_audit('8bc9eef5-dcd5-46b1-b931-23f77132322c')$q$,'FORBIDDEN');
SELECT public.expect_stock_audit_error($q$SELECT public.cancel_inventory_stock_audit('8bc9eef5-dcd5-46b1-b931-23f77132322c',test_uuid(999),1)$q$,'FORBIDDEN');
SELECT 'Stocktake drafts, scope, precision, snapshots, completion, exclusions, cancellation, retry: PASS';
