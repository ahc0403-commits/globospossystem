SET fixture.super_admin='true';
SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
-- These two retired scheduler entry points are not needed by the reporting
-- fixture. Stubs exist only to exercise the migration's privilege retirement.
CREATE FUNCTION restaurant_finalize_daily_sales() RETURNS void LANGUAGE sql AS 'SELECT';
CREATE FUNCTION restaurant_finalize_daily_sales_at(date,timestamptz) RETURNS void LANGUAGE sql AS 'SELECT';
REVOKE ALL ON FUNCTION restaurant_finalize_daily_sales(),restaurant_finalize_daily_sales_at(date,timestamptz) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION restaurant_finalize_daily_sales() TO service_role;
CREATE SCHEMA cron;
CREATE TABLE cron.job(jobname text PRIMARY KEY,active boolean);
INSERT INTO cron.job VALUES('restaurant-daily-sales-finalize-2220-hcm',true),('daily-closing-2300-hcm',true);
CREATE TABLE owner_sales_baseline AS SELECT
 get_pos_daily_sales_export_page('2026-10-08','10000000-0000-0000-0000-000000000001','restaurant_pos') page,
 get_restaurant_daily_sales_exports_by_tax_entity('2026-10-08') grouped,
 md5(pg_get_functiondef('get_pos_daily_sales_summary(date)'::regprocedure)) summary,
 md5(pg_get_functiondef('get_pos_daily_sales_summary(date,boolean)'::regprocedure)) summary_overload,
 md5(pg_get_functiondef('pos_restaurant_receipt_rows_v2(date,uuid[])'::regprocedure)) receipt_source;
INSERT INTO restaurant_daily_sales_finalizations VALUES('2026-10-08','data_integrity_failed',NULL);
CREATE TABLE owner_sales_history AS SELECT md5(jsonb_agg(to_jsonb(f) ORDER BY business_date)::text) hash FROM restaurant_daily_sales_finalizations f;
DO $$ BEGIN
 BEGIN
  PERFORM get_pos_daily_sales_export_page('2026-10-08','10000000-0000-0000-0000-000000000001','restaurant_pos');
  RAISE EXCEPTION 'EXPECTED_LEGACY_TIME_GATE';
 EXCEPTION WHEN others THEN
  IF SQLERRM<>'RESTAURANT_EXPORT_DATA_INTEGRITY_FAILED' THEN RAISE; END IF;
 END;
 PERFORM fixture_assert(get_restaurant_daily_sales_exports_by_tax_entity('2026-10-08')->>'status'='data_integrity_failed','reproduce legacy scheduled-failure report block');
END $$;
