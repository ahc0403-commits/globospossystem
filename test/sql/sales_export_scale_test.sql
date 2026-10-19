SET fixture.super_admin='true';
SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
-- Synthetic 105 Restaurant + 464 Photo receipts; eight combo source items
-- split into two rates. Scale ten uses different receipts with the same shape.
INSERT INTO orders SELECT md5('scale-order-'||scale||'-'||i)::uuid,'completed','dine_in' FROM (VALUES(1),(10))s(scale) CROSS JOIN LATERAL generate_series(1,105*scale)i;
INSERT INTO order_items(id,order_id,menu_item_id,display_name,quantity,unit_price,total_amount_ex_tax,vat_rate,vat_amount,paying_amount_inc_tax,vat_breakdown,created_at,status,item_type)
SELECT md5('scale-item-'||scale||'-'||i||'-'||l)::uuid,md5('scale-order-'||scale||'-'||i)::uuid,md5('fixture-menu-2')::uuid,'Synthetic food',1,
 CASE WHEN (i-1)%105<8 AND l=1 THEN 200 ELSE 100 END,CASE WHEN (i-1)%105<8 AND l=1 THEN 200 ELSE 100 END,
 CASE WHEN (i-1)%105<8 AND l=1 THEN -1 ELSE 8 END,CASE WHEN (i-1)%105<8 AND l=1 THEN 18 ELSE 8 END,
 CASE WHEN (i-1)%105<8 AND l=1 THEN 218 ELSE 108 END,
 CASE WHEN (i-1)%105<8 AND l=1 THEN '[{"vat_rate":8,"total_amount_ex_tax":100,"vat_amount":8,"paying_amount_inc_tax":108},{"vat_rate":10,"total_amount_ex_tax":100,"vat_amount":10,"paying_amount_inc_tax":110}]'::jsonb END,
 CASE WHEN scale=1 THEN '2026-10-06 12:00+07'::timestamptz ELSE '2026-10-07 12:00+07'::timestamptz END,'served','menu_item'
FROM (VALUES(1),(10))s(scale) CROSS JOIN LATERAL generate_series(1,105*scale)i
 CROSS JOIN LATERAL generate_series(1,5+CASE WHEN (i-1)%105<45 THEN 1 ELSE 0 END-CASE WHEN (i-1)%105<8 THEN 1 ELSE 0 END)l;
INSERT INTO payments(order_id,restaurant_id,created_at,amount_portion,amount,method,is_revenue)
SELECT order_id,'20000000-0000-0000-0000-000000000001',max(created_at),sum(paying_amount_inc_tax),sum(paying_amount_inc_tax),'CASH',true FROM order_items WHERE display_name='Synthetic food' GROUP BY order_id;
INSERT INTO photo_objet_sales_raw SELECT 'SCALE-PHOTO-'||scale||'-'||lpad(i::text,5,'0'),'20000000-0000-0000-0000-000000000002',CASE WHEN scale=1 THEN '2026-10-06 12:00+07'::timestamptz ELSE '2026-10-07 12:00+07'::timestamptz END,10800,CASE WHEN scale=1 THEN DATE '2026-10-06' ELSE DATE '2026-10-07' END,2,'Synthetic Photo' FROM (VALUES(1),(10))s(scale) CROSS JOIN LATERAL generate_series(1,464*scale)i;
ANALYZE public.payments;ANALYZE public.order_items;ANALYZE public.photo_objet_sales_raw;
DO $$DECLARE scale integer; day date; response jsonb; last jsonb; source text; ct integer; lines integer; calls integer; response_bytes bigint; started timestamptz; after_time timestamptz;after_id text;page_started timestamptz; max_page_ms numeric; BEGIN
 FOREACH scale IN ARRAY ARRAY[1,10] LOOP
  day:=CASE WHEN scale=1 THEN DATE '2026-10-06' ELSE DATE '2026-10-07' END;
  ct:=0;lines:=0;calls:=1;response_bytes:=0;max_page_ms:=0;started:=clock_timestamp();
  response:=get_pos_daily_sales_summary(day);
  PERFORM fixture_assert(EXISTS(SELECT 1 FROM jsonb_array_elements(response->'entities') e WHERE e->>'tax_entity_id'='10000000-0000-0000-0000-000000000001' AND (e->>'source_item_count')::int=1026*scale AND (e->>'export_line_count')::int=1034*scale),'SQL combo source/line counts at scale '||scale);
  response_bytes:=octet_length(response::text);
  FOREACH source IN ARRAY ARRAY['restaurant_pos','photo_objet_moers'] LOOP
   after_time:=NULL;after_id:=NULL;
   LOOP
    page_started:=clock_timestamp();response:=get_pos_daily_sales_export_page(day,'10000000-0000-0000-0000-000000000001',source,after_time,after_id,100);calls:=calls+1;
    max_page_ms:=greatest(max_page_ms,extract(epoch FROM clock_timestamp()-page_started)*1000);
    response_bytes:=response_bytes+octet_length(response::text);ct:=ct+jsonb_array_length(response->'rows');
    SELECT lines+COALESCE(sum(CASE WHEN source='restaurant_pos' THEN jsonb_array_length(r->'line_items') ELSE 1 END),0) INTO lines FROM jsonb_array_elements(response->'rows')r;
    EXIT WHEN jsonb_array_length(response->'rows')<100;
    last:=response->'rows'->99;after_time:=(last->>'sold_at')::timestamptz;after_id:=CASE WHEN source='restaurant_pos' THEN last->>'receipt_id' ELSE last->>'source_hash' END;
   END LOOP;
  END LOOP;
  PERFORM fixture_assert(ct=569*scale AND lines=1034*scale,'page completeness at scale '||scale);
  PERFORM fixture_assert(calls=CASE WHEN scale=1 THEN 8 ELSE 59 END,'RPC-equivalent calls bounded at scale '||scale);
  RAISE NOTICE 'SALES_SQL_METRICS receipts=% lines=% calls=% bytes=% elapsed_ms=% max_page_ms=%',ct,lines,calls,response_bytes,round(extract(epoch FROM clock_timestamp()-started)*1000,2),round(max_page_ms,2);
 END LOOP;
END $$;
-- Inspect the actual function body, so EXPLAIN does not hide reads inside a
-- SECURITY DEFINER Function Scan. Source rows are synthetic and remain private.
DO $$DECLARE q text; plan jsonb; BEGIN
 SELECT prosrc INTO q FROM pg_proc WHERE oid='public.pos_daily_receipt_scope_page(date,uuid,timestamptz,text,integer)'::regprocedure;
 q:=replace(replace(replace(replace(replace(q,'p_business_date','DATE ''2026-10-07'''),'p_tax_entity_id','''10000000-0000-0000-0000-000000000001''::uuid'),'p_after_time','NULL::timestamptz'),'p_after_id','NULL::text'),'p_limit','100');
 EXECUTE 'EXPLAIN(ANALYZE,BUFFERS,FORMAT JSON) '||q INTO plan;
 RAISE NOTICE 'SALES_SQL_SCOPE_PLAN %',plan;
 SELECT prosrc INTO q FROM pg_proc WHERE oid='public.pos_photo_receipt_rows_page(date,uuid,timestamptz,text,integer)'::regprocedure;
 q:=replace(replace(replace(replace(replace(q,'p_business_date','DATE ''2026-10-07'''),'p_tax_entity_id','''10000000-0000-0000-0000-000000000001''::uuid'),'p_after_time','''2026-10-07 12:00+07''::timestamptz'),'p_after_id','''SCALE-PHOTO-10-04500''::text'),'p_limit','100');
 EXECUTE 'EXPLAIN(ANALYZE,BUFFERS,FORMAT JSON) '||q INTO plan;
 RAISE NOTICE 'SALES_SQL_PHOTO_PLAN %',plan;
END $$;
