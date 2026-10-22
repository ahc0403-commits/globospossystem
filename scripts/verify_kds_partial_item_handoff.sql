\set ON_ERROR_STOP on
DO $$DECLARE d text; BEGIN
 d:=pg_get_functiondef('public.kds_record_station_progress_v3(uuid,text,text,integer,uuid)'::regprocedure);
 IF position('v_done <> v_started' IN d)>0 OR position('v_started > v_required' IN d)=0
  OR position('kds_record_direct_preparation_v1(' IN d)=0
  OR position('store_assignment_area_codes_v1' IN d)=0 THEN RAISE EXCEPTION 'KDS_PARTIAL_CHAIN_VERIFY_FAILED'; END IF;
 d:=pg_get_functiondef('public.kds_serve_ready_order_v3(uuid,uuid)'::regprocedure);
 IF d ~* '\m(loop|foreach)\M' OR position('kds_record_station_progress_v3(' IN d)>0
  OR position('kds_apply_station_progress_batch_v1(' IN d)=0 OR position('LIMIT 1001' IN d)=0
  OR position('store_assignment_area_codes_v1' IN d)=0 THEN RAISE EXCEPTION 'KDS_PARTIAL_SET_VERIFY_FAILED'; END IF;
 d:=pg_get_functiondef('public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)'::regprocedure);
 IF position('LEFT JOIN LATERAL' IN d)>0 OR position('WITH allocations AS MATERIALIZED' IN d)=0 THEN
  RAISE EXCEPTION 'KDS_PARTIAL_LOT_VERIFY_FAILED'; END IF;
 IF has_function_privilege('anon','public.kds_serve_ready_order_v3(uuid,uuid)','EXECUTE')
  OR has_function_privilege('authenticated','public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)','EXECUTE')
  OR has_function_privilege('authenticated','public.kds_record_station_progress_before_partial(uuid,text,text,integer,uuid)','EXECUTE')
  OR has_function_privilege('authenticated','public.kds_serve_ready_order_before_partial(uuid,uuid)','EXECUTE')
  OR has_function_privilege('authenticated','public.kds_apply_station_progress_before_partial(uuid,uuid,uuid,text,text,jsonb)','EXECUTE') THEN
  RAISE EXCEPTION 'KDS_PARTIAL_PRIVILEGE_VERIFY_FAILED'; END IF;
END$$;
