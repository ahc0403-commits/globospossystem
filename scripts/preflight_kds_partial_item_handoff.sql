\set ON_ERROR_STOP on
DO $$DECLARE d text; BEGIN
 d:=pg_get_functiondef('public.kds_record_station_progress_v3(uuid,text,text,integer,uuid)'::regprocedure);
 IF position('OR v_done <> v_started OR v_done < 0 OR v_done > v_required' IN d)=0
  OR position('kds_record_direct_preparation_v1(' IN d)=0
  OR position('store_assignment_area_codes_v1' IN d)=0 THEN
  RAISE EXCEPTION 'KDS_PARTIAL_PREDECESSOR_DRIFT'; END IF;
 PERFORM 'public.kds_serve_ready_order_v3(uuid,uuid)'::regprocedure;
 PERFORM 'public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)'::regprocedure;
END$$;
