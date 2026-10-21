-- Full current-schema reporting contract, following the real payment fixtures.
BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
DO $$ DECLARE report jsonb; entity jsonb; j jsonb; b jsonb; no_sales uuid; day date:=(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
BEGIN
 INSERT INTO public.restaurants(name,brand_id,tax_entity_id)
 VALUES('Harbor Kitchen','91000000-0000-4000-8000-000000000003','91000000-0000-4000-8000-000000000004') RETURNING id INTO no_sales;
 report:=public.get_pos_daily_sales_summary(day,false);
 SELECT e INTO entity FROM jsonb_array_elements(report->'entities')e WHERE e->>'tax_entity_id'='91000000-0000-4000-8000-000000000004';
 ASSERT entity IS NOT NULL,'fixture tax entity missing';
 SELECT e INTO j FROM jsonb_array_elements(entity->'restaurant_stores')e WHERE e->>'store_id'='273b057e-3b69-46e3-93c1-6194c2802849';
 SELECT e INTO b FROM jsonb_array_elements(entity->'restaurant_stores')e WHERE e->>'store_id'='8bc9eef5-dcd5-46b1-b931-23f77132322c';
 ASSERT j IS NOT NULL AND (j->>'receipt_count')::int=1 AND (j->>'gross')::numeric=10800,'JeonGabok reported sales changed';
 ASSERT b IS NOT NULL AND (b->>'receipt_count')::int=2 AND (b->>'gross')::numeric=21600,'Bunsik reported sales changed';
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(entity->'restaurant_stores')e WHERE e->>'store_id'=no_sales::text AND e->>'closing_status'='no_sales'),'registered no-sales store missing';
 ASSERT (SELECT jsonb_agg(e-'export_metadata_deferred') FROM jsonb_array_elements(public.get_pos_daily_sales_summary(day)->'entities')e)
  =(SELECT jsonb_agg(e-'export_metadata_deferred') FROM jsonb_array_elements(public.get_pos_daily_sales_summary(day,true)->'entities')e),'report overloads disagree';
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000001',true);
 BEGIN PERFORM public.get_pos_daily_sales_summary(day,false); RAISE EXCEPTION 'report scope bypassed';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'SUPER_ADMIN_ONLY' THEN RAISE; END IF; END;
 RAISE NOTICE 'OPERATING_ALL_STORE_SALES=PASS both overloads, two stores, new no-sales store, permission';
END $$;
ROLLBACK;
