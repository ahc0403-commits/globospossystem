-- Read-only bounded operational diagnostics. No business rows or credentials.
SELECT clock_timestamp() AS observed_at,
 count(*) AS connections,
 count(*) FILTER(WHERE state='active') AS active_connections,
 count(*) FILTER(WHERE wait_event_type='Lock') AS waiting_on_lock
FROM pg_stat_activity WHERE datname=current_database();

SELECT queryid,calls,round(total_exec_time::numeric,1) AS total_ms,
 round(mean_exec_time::numeric,1) AS mean_ms,rows
FROM extensions.pg_stat_statements
WHERE dbid=(SELECT oid FROM pg_database WHERE datname=current_database())
ORDER BY total_exec_time DESC LIMIT 20;

SELECT p.proname,pg_get_function_identity_arguments(p.oid) AS arguments,
 md5(pg_get_functiondef(p.oid)) AS definition_hash
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname IN (
 'process_payment','sync_active_order_promotion','sync_changed_order_promotions_v1',
 'emit_menu_discount_quantity_event_v1','get_kds_sync_config','get_kds_high_watermark_v2');
