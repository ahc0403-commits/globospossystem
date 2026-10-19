SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
SELECT fixture_assert((pos_receipt_ledger_batch('2026-09-04','10000000-0000-0000-0000-000000000001',ARRAY['30000000-0000-0000-0000-000000000001'::uuid],false)->'rows'->0->'payments') IS NOT NULL,'ledger payment breakdown batch');
DO $$ BEGIN
 BEGIN PERFORM pos_receipt_ledger_batch('2026-09-04','10000000-0000-0000-0000-000000000001',ARRAY['30000000-0000-0000-0000-000000000002'::uuid],false);RAISE EXCEPTION 'FAIL';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'POS_LEDGER_SCOPE_CHANGED' THEN RAISE; END IF; END;
 BEGIN PERFORM pos_receipt_ledger_batch('2026-09-04','10000000-0000-0000-0000-000000000002',ARRAY['30000000-0000-0000-0000-000000000001'::uuid],false);RAISE EXCEPTION 'FAIL';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'POS_LEDGER_SCOPE_CHANGED' THEN RAISE; END IF; END;
 BEGIN PERFORM pos_receipt_ledger_batch('2026-09-04','10000000-0000-0000-0000-000000000001',ARRAY(SELECT gen_random_uuid() FROM generate_series(1,51)),false);RAISE EXCEPTION 'FAIL';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'POS_LEDGER_SCOPE_INVALID' THEN RAISE; END IF; END;
END $$;
SET fixture.super_admin='false';
DO $$ BEGIN
 BEGIN PERFORM pos_receipt_ledger_batch('2026-09-04','10000000-0000-0000-0000-000000000001',ARRAY['30000000-0000-0000-0000-000000000001'::uuid],false);RAISE EXCEPTION 'FAIL';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'SUPER_ADMIN_ONLY' THEN RAISE; END IF; END;
END $$;
SET fixture.super_admin='true';
-- Scale using synthetic completed receipts; one report and bounded page batches.
DO $$ DECLARE size integer;response jsonb;started timestamptz;ids uuid[];page jsonb;BEGIN
 FOREACH size IN ARRAY ARRAY[10,100,1000] LOOP
  INSERT INTO orders SELECT md5('ledger-'||size||'-'||i)::uuid,'completed','dine_in' FROM generate_series(1,size) i;
  INSERT INTO payments(order_id,restaurant_id,created_at,amount_portion,amount,method,is_revenue)
  SELECT md5('ledger-'||size||'-'||i)::uuid,'20000000-0000-0000-0000-000000000001',('2026-09-05 12:00+07'::timestamptz+make_interval(days=>CASE size WHEN 10 THEN 0 WHEN 100 THEN 1 ELSE 2 END)),108,108,'CASH',true FROM generate_series(1,size) i;
  INSERT INTO order_items SELECT gen_random_uuid(),md5('ledger-'||size||'-'||i)::uuid,'Meal','Meal',1,100,100,8,8,now(),'active',false,'menu_item' FROM generate_series(1,size) i;
  started:=clock_timestamp();response:=get_restaurant_daily_sales_exports_by_tax_entity(CASE size WHEN 10 THEN '2026-09-05'::date WHEN 100 THEN '2026-09-06'::date ELSE '2026-09-07'::date END);
  PERFORM fixture_assert((response->'entities'->0->>'receipt_count')::int=size,'scale count '||size);
  SELECT array_agg(md5('ledger-'||size||'-'||i)::uuid) INTO ids FROM generate_series(1,least(size,50)) i;
  page:=pos_receipt_ledger_batch(CASE size WHEN 10 THEN '2026-09-05'::date WHEN 100 THEN '2026-09-06'::date ELSE '2026-09-07'::date END,'10000000-0000-0000-0000-000000000001',ids,false);
  PERFORM fixture_assert(jsonb_array_length(page->'rows')=least(size,50),'batch capped '||size);
  RAISE NOTICE 'LEDGER_SIZE=% report_bytes=% page_bytes=% report_plus_page_ms=% page_rpc=1 detail_rpc=0',size,octet_length(response::text),octet_length(page::text),extract(epoch from clock_timestamp()-started)*1000;
 END LOOP;
END $$;
SELECT fixture_assert((get_restaurant_daily_sales_exports_by_tax_entity('2026-09-04')#>>'{entities,0,receipts,0,receipt_number}')='BC-20260904-000001','real receipt number distinct from order/payment IDs');
EXPLAIN (ANALYZE,BUFFERS) SELECT * FROM pos_restaurant_receipt_rows('2026-09-07',ARRAY(SELECT md5('ledger-1000-'||i)::uuid FROM generate_series(1,50) i));
-- Inspect the underlying set-based query rather than only the SQL function's
-- outer Function Scan. These indexes model the production key read paths.
CREATE INDEX fixture_payment_order ON payments(order_id);
CREATE INDEX fixture_payment_time ON payments(created_at);
CREATE INDEX fixture_item_order ON order_items(order_id);
ANALYZE payments;ANALYZE order_items;ANALYZE orders;
DO $$ DECLARE d text;plan_row record;BEGIN
 SELECT prosrc INTO d FROM pg_proc WHERE oid='pos_restaurant_receipt_rows(date,uuid[])'::regprocedure;
 d:=replace(replace(d,'p_business_date','DATE ''2026-09-07'''),'p_order_ids','ARRAY(SELECT md5(''ledger-1000-''||i)::uuid FROM generate_series(1,50) i)');
 FOR plan_row IN EXECUTE 'EXPLAIN (ANALYZE,BUFFERS,FORMAT TEXT) '||d LOOP RAISE NOTICE '%',plan_row."QUERY PLAN"; END LOOP;
END $$;
