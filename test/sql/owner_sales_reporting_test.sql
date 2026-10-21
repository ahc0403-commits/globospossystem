SET fixture.super_admin='true';
SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
DO $$DECLARE p jsonb;g jsonb;b record;started timestamptz:=clock_timestamp(); BEGIN
 SELECT * INTO b FROM owner_sales_baseline;
 p:=get_pos_daily_sales_export_page('2026-10-08','10000000-0000-0000-0000-000000000001','restaurant_pos');
 g:=get_restaurant_daily_sales_exports_by_tax_entity('2026-10-08');
 PERFORM fixture_assert(p=b.page AND g=b.grouped,'legacy scheduled failure does not change any report receipt, amount, VAT, snapshot or fingerprint');
 PERFORM fixture_assert(EXISTS(SELECT 1 FROM jsonb_array_elements(p->'rows') r WHERE r->>'receipt_id'='31000000-0000-0000-0000-000000000001' AND (r->>'sold_at')::timestamptz='2026-10-08 23:32+07' AND (r->>'gross_sales')::numeric=439560),'late 23:32 completed receipt remains fully reportable');
 PERFORM fixture_assert(g->>'status'='ready' AND g->>'finalized_at' IS NULL,'report readiness does not fabricate owner finalization');
 PERFORM fixture_assert((SELECT hash FROM owner_sales_history)=(SELECT md5(jsonb_agg(to_jsonb(f) ORDER BY business_date)::text) FROM restaurant_daily_sales_finalizations f),'immutable historical failures and finalizations are untouched');
 PERFORM fixture_assert(b.summary=md5(pg_get_functiondef('get_pos_daily_sales_summary(date)'::regprocedure)) AND b.summary_overload=md5(pg_get_functiondef('get_pos_daily_sales_summary(date,boolean)'::regprocedure)) AND b.receipt_source=md5(pg_get_functiondef('pos_restaurant_receipt_rows_v2(date,uuid[])'::regprocedure)),'all-store summaries and actual invoice source unchanged');
 PERFORM fixture_assert(NOT (SELECT active FROM cron.job WHERE jobname='restaurant-daily-sales-finalize-2220-hcm') AND (SELECT active FROM cron.job WHERE jobname='daily-closing-2300-hcm'),'retire only automatic sales finalization schedule');
 PERFORM fixture_assert(NOT has_function_privilege('service_role','restaurant_finalize_daily_sales()','EXECUTE') AND NOT has_function_privilege('authenticated','restaurant_finalize_daily_sales_at(date,timestamptz)','EXECUTE'),'application roles cannot run automatic sales finalizer');
 PERFORM fixture_assert(get_restaurant_daily_sales_exports_by_tax_entity((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date+1)->>'status'='pending','future-date guard retained');
 RAISE NOTICE 'OWNER_SALES_REPORT_METRICS receipts=% page_bytes=% grouped_bytes=% elapsed_ms=%',jsonb_array_length(p->'rows'),octet_length(p::text),octet_length(g::text),round(extract(epoch FROM clock_timestamp()-started)*1000,2);
END $$;
SET fixture.super_admin='false';
DO $$ BEGIN
 BEGIN PERFORM get_pos_daily_sales_export_page('2026-10-08','10000000-0000-0000-0000-000000000001','restaurant_pos'); RAISE EXCEPTION 'PAGE_AUTH_BYPASS'; EXCEPTION WHEN others THEN IF SQLERRM<>'SUPER_ADMIN_ONLY' THEN RAISE; END IF; END;
 BEGIN PERFORM get_restaurant_daily_sales_exports_by_tax_entity('2026-10-08'); RAISE EXCEPTION 'GROUPED_AUTH_BYPASS'; EXCEPTION WHEN others THEN IF SQLERRM<>'RESTAURANT_SALES_EXPORT_FORBIDDEN' THEN RAISE; END IF; END;
END $$;
SET fixture.super_admin='true';
SELECT 'OWNER_SALES_REPORTING=PASS' AS result;
