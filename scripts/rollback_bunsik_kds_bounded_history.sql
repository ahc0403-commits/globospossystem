-- Read functions only. Deploy the previous compatible web build before using
-- this rollback: the new paged-history RPC is removed. Prefer a forward fix.
BEGIN;
SET LOCAL lock_timeout='5s';
DROP FUNCTION public.get_emergency_station_today_completed();
ALTER FUNCTION public.get_emergency_station_today_completed_pre_bunsik() RENAME TO get_emergency_station_today_completed;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_today_completed() TO authenticated;
DROP FUNCTION public.get_bunsik_kds_completed_page_v1(integer,timestamptz,uuid);
DROP FUNCTION public.get_emergency_station_snapshot();
ALTER FUNCTION public.get_emergency_station_snapshot_pre_bunsik() RENAME TO get_emergency_station_snapshot;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_snapshot() TO authenticated;
DROP FUNCTION public.get_emergency_station_today_completed_base();
ALTER FUNCTION public.get_emergency_station_today_completed_base_pre_bunsik() RENAME TO get_emergency_station_today_completed_base;
DROP FUNCTION public.emergency_add_order_batch_timings(jsonb);
ALTER FUNCTION public.emergency_add_order_batch_timings_pre_bunsik(jsonb) RENAME TO emergency_add_order_batch_timings;
DROP FUNCTION public.bunsik_kds_enrich_orders_v1(jsonb,text);
DROP FUNCTION public.bunsik_kds_add_component_progress_v1(jsonb);
DROP FUNCTION public.bunsik_kds_localize_orders_v1(jsonb);
DROP FUNCTION public.bunsik_kds_batch_timings_v1(jsonb);
DROP FUNCTION public.bunsik_kds_completed_core_v1(integer,timestamptz,uuid);
NOTIFY pgrst,'reload schema';
COMMIT;
