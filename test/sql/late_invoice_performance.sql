SET request.jwt.claim.sub='00000000-0000-4000-8000-000000000001';
UPDATE digital_receipts SET receipt_number='PAGE-'||receipt_number WHERE order_id=ANY(SELECT md5('late-order-'||i)::uuid FROM generate_series(100,599)i);
DO $$DECLARE p jsonb;last jsonb;cursor_at timestamptz;cursor_id text;seen text[]:='{}';n integer;bytes bigint:=0;started timestamptz:=clock_timestamp();BEGIN
 FOR n IN 1..10 LOOP
  p:=get_receipt_ledger_page((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,late_fixture.shop(1),'PAGE-',NULL,50,0,cursor_at,cursor_id,n=1);
  PERFORM fixture_assert(jsonb_array_length(p->'receipts')=50,'keyset page '||n||' returns 50');
  SELECT seen||array_agg(r->>'receipt_id') INTO seen FROM jsonb_array_elements(p->'receipts') r;
  last:=p->'receipts'->49;cursor_at:=(last->>'sold_at')::timestamptz;cursor_id:=last->>'receipt_id';bytes:=bytes+octet_length(p::text);
 END LOOP;
 PERFORM fixture_assert((SELECT count(DISTINCT x)=500 FROM unnest(seen)x),'500 receipts have no missing or repeated cursor rows');
 RAISE NOTICE 'LATE_INVOICE_PAGING rows=500 page_size=50 client_calls=10 total_bytes=% elapsed_ms=%',bytes,round(extract(epoch FROM clock_timestamp()-started)*1000,2);
END $$;
SELECT late_fixture.sale(i) FROM generate_series(700,749)i;
INSERT INTO combined_payment_groups VALUES(md5('late-50-group')::uuid,now());
UPDATE payments SET combined_payment_group_id=md5('late-50-group')::uuid WHERE order_id=ANY(SELECT md5('late-order-'||i)::uuid FROM generate_series(700,749)i);
INSERT INTO meinvoice_jobs(order_id,store_id,tax_entity_id,buyer_snapshot,line_items_snapshot)
SELECT md5('late-order-'||i)::uuid,late_fixture.shop(1),md5('late-tax')::uuid,'{"customer_name":"Anonymous"}','[{"display_name":"Frozen fixture line"}]' FROM generate_series(700,749)i;
SELECT pg_stat_reset();
DO $$DECLARE c jsonb;r jsonb;started timestamptz:=clock_timestamp();BEGIN
 SELECT jsonb_build_object('versions',jsonb_object_agg(p.order_id::text,'null'::jsonb)) INTO c
 FROM payments p WHERE combined_payment_group_id=md5('late-50-group')::uuid;
 r:=pos_submit_late_invoice(gen_random_uuid(),late_fixture.shop(1),NULL,md5('late-50-group')::uuid,c->'versions',late_fixture.patch(),true);
 PERFORM fixture_assert(jsonb_array_length(r->'order_ids')=50,'combined write includes all 50 orders');
 PERFORM fixture_assert((SELECT count(*)=50 FROM meinvoice_job_snapshot_versions v JOIN meinvoice_jobs j ON j.id=v.job_id JOIN payments p ON p.order_id=j.order_id WHERE p.combined_payment_group_id=md5('late-50-group')::uuid),'50 previous snapshots archived in one statement');
 RAISE NOTICE 'LATE_INVOICE_WRITE orders=50 client_calls=1 bytes=% elapsed_ms=%',octet_length(r::text),round(extract(epoch FROM clock_timestamp()-started)*1000,2);
END $$;
