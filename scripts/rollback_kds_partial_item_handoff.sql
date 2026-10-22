\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout='5s';
DO $$DECLARE d text; BEGIN
 d:=pg_get_functiondef('public.kds_record_station_progress_before_partial(uuid,text,text,integer,uuid)'::regprocedure);
 EXECUTE replace(d,'FUNCTION public.kds_record_station_progress_before_partial(','FUNCTION public.kds_record_station_progress_v3(');
 d:=pg_get_functiondef('public.kds_serve_ready_order_before_partial(uuid,uuid)'::regprocedure);
 EXECUTE replace(d,'FUNCTION public.kds_serve_ready_order_before_partial(','FUNCTION public.kds_serve_ready_order_v3(');
 d:=pg_get_functiondef('public.kds_apply_station_progress_before_partial(uuid,uuid,uuid,text,text,jsonb)'::regprocedure);
 EXECUTE replace(d,'FUNCTION public.kds_apply_station_progress_before_partial(','FUNCTION public.kds_apply_station_progress_batch_v1(');
END$$;
DROP FUNCTION public.kds_record_station_progress_before_partial(uuid,text,text,integer,uuid);
DROP FUNCTION public.kds_serve_ready_order_before_partial(uuid,uuid);
DROP FUNCTION public.kds_apply_station_progress_before_partial(uuid,uuid,uuid,text,text,jsonb);
COMMIT;
