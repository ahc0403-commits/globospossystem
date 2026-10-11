SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
SELECT fixture_assert((get_store_collection_bank('20000000-0000-0000-0000-000000000099')->>'account_number')='80002014298','AKJ MSB corporate bank');
SELECT fixture_assert((SELECT collection_bank_snapshot->>'account_number'='100202042976' FROM direct_order_sessions WHERE id='90000000-0000-0000-0000-000000000001'),'legacy session preserves beneficiary');
INSERT INTO direct_order_sessions(restaurant_id) VALUES('20000000-0000-0000-0000-000000000099');
SELECT fixture_assert((SELECT count(*)=1 FROM direct_order_sessions WHERE collection_bank_snapshot->>'account_number'='80002014298'),'new session uses corporate bank');
SELECT fixture_assert((SELECT count(*)=1 FROM tax_entity_collection_accounts),'other entity accounts untouched');
SELECT fixture_assert((direct_order_admin_get_storefront('20000000-0000-0000-0000-000000000099')->>'collection_bank_managed')::boolean,'canonical account disclosed in settings');
DELETE FROM direct_order_storefronts WHERE restaurant_id='20000000-0000-0000-0000-000000000099';
SELECT fixture_assert((direct_order_admin_get_storefront('20000000-0000-0000-0000-000000000099')->>'collection_bank_managed')::boolean
 AND direct_order_admin_get_storefront('20000000-0000-0000-0000-000000000099')->>'bank_account_number'='80002014298','first storefront setup uses canonical corporate bank');
SELECT fixture_assert(EXISTS(SELECT 1 FROM jsonb_array_elements(get_pos_daily_sales_summary('2026-10-08')->'entities') e
 WHERE e->>'tax_entity_id'='a6bda671-4179-5a29-a798-76357b42b497' AND (e->>'restaurant_receipt_count')::int=0
 AND e->'bank'->>'account_number'='80002014298'),'bank settings available before first sale');
INSERT INTO orders VALUES('31000000-0000-0000-0000-000000000001','completed','dine_in');
INSERT INTO payments(order_id,restaurant_id,created_at,amount_portion,amount,method,is_revenue) VALUES('31000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','2026-10-08 23:32+07',439560,439560,'BANKTRANSFER',true);
INSERT INTO digital_receipts(order_id,restaurant_id,receipt_number) VALUES('31000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','BC-20261008-023320');
INSERT INTO menu_items SELECT md5('fixture-menu-'||i)::uuid,'20000000-0000-0000-0000-000000000001',CASE i WHEN 1 THEN 'Cola' WHEN 2 THEN 'Fanta' ELSE 'Approved menu '||i END,CASE i WHEN 1 THEN 10 ELSE 8 END FROM generate_series(1,9)i;
INSERT INTO menu_invoice_profiles(menu_item_id,invoice_name_vi,unit_name,effective_from) SELECT id,name,CASE name WHEN 'Cola' THEN 'Chai' WHEN 'Fanta' THEN 'Chai' ELSE 'Phần' END,'2026-10-01+07' FROM menu_items;
INSERT INTO order_items(id,order_id,menu_item_id,display_name,quantity,unit_price,total_amount_ex_tax,vat_rate,vat_amount,paying_amount_inc_tax,created_at,status,item_type)
SELECT md5('fixture-item-'||i)::uuid,'31000000-0000-0000-0000-000000000001',md5('fixture-menu-'||i)::uuid,'Original item '||i,CASE i WHEN 9 THEN 2 ELSE 1 END,40000,
 CASE i WHEN 1 THEN 54000 WHEN 2 THEN 32000 WHEN 9 THEN 80000 ELSE 40000 END,CASE i WHEN 1 THEN 10 ELSE 8 END,
 CASE i WHEN 1 THEN 5400 WHEN 2 THEN 2560 WHEN 9 THEN 6400 ELSE 3200 END,
 CASE i WHEN 1 THEN 59400 WHEN 2 THEN 34560 WHEN 9 THEN 86400 ELSE 43200 END,'2026-10-08 22:00+07','served','menu_item' FROM generate_series(1,9)i;
DO $$DECLARE r record; BEGIN
 SELECT * INTO r FROM pos_restaurant_receipt_rows_v2('2026-10-08');
 PERFORM fixture_assert(r.receipt_number='BC-20261008-023320' AND r.payment_method='CK','reference receipt bank transfer');
 PERFORM fixture_assert(jsonb_array_length(r.line_items)=9 AND (SELECT sum((v->>'quantity')::numeric)=10 FROM jsonb_array_elements(r.line_items)v),'9 menu lines 10 units preserved');
 PERFORM fixture_assert((SELECT sum((v->>'total_amount_ex_tax')::numeric)=406000 AND sum((v->>'vat_amount')::numeric)=33560 FROM jsonb_array_elements(r.line_items)v) AND r.gross_sales=439560,'reference supply VAT gross preserved');
 PERFORM fixture_assert(r.line_items @> '[{"invoice_name_vi":"Cola","vat_rate":10},{"invoice_name_vi":"Fanta","vat_rate":8}]','Cola 10 Fanta 8 preserved');
END $$;
INSERT INTO meinvoice_jobs(id,order_id,source_system,created_at,tax_entity_id,payment_method_snapshot,line_items_snapshot,payment_summary,snapshot_version)
VALUES('61000000-0000-0000-0000-000000000001','31000000-0000-0000-0000-000000000001','restaurant_pos',now(),'10000000-0000-0000-0000-000000000001','Ví điện tử/QR','[{"display_name":"Dịch vụ ăn uống"}]','{"methods":["BANKTRANSFER"]}',1);
SELECT fixture_assert(refresh_meinvoice_export_snapshots('2026-10-08','10000000-0000-0000-0000-000000000001',ARRAY['31000000-0000-0000-0000-000000000001'::uuid])=1,'unissued snapshot version refreshed');
SELECT fixture_assert((SELECT snapshot_version=2 AND payment_method_snapshot='CK' AND jsonb_array_length(line_items_snapshot)=9 FROM meinvoice_jobs WHERE id='61000000-0000-0000-0000-000000000001'),'pending corrected snapshot');
SELECT fixture_assert((SELECT count(*)=1 AND bool_and(payment_method_snapshot='Ví điện tử/QR') FROM meinvoice_job_snapshot_versions),'original error snapshot archived');
SELECT approve_menu_invoice_profile(md5('fixture-menu-1')::uuid,'Cola newly approved description','Chai','2026-10-09 00:00+07');
SELECT fixture_assert((SELECT vat_rate=10 FROM menu_items WHERE id=md5('fixture-menu-1')::uuid)
 AND (SELECT vat_rate=8 FROM menu_items WHERE id=md5('fixture-menu-2')::uuid),'description approval keeps beverage master VAT');
SELECT fixture_assert((SELECT line_items @> '[{"invoice_name_vi":"Cola","vat_rate":10},{"invoice_name_vi":"Fanta","vat_rate":8}]'
 FROM pos_restaurant_receipt_rows_v2('2026-10-08',ARRAY['31000000-0000-0000-0000-000000000001'::uuid])),'new description approval does not rewrite sold snapshot');
UPDATE meinvoice_jobs SET status='valid_invoice',invoice_number='FIXTURE-ORIGINAL' WHERE id='61000000-0000-0000-0000-000000000001';
DO $$BEGIN BEGIN UPDATE meinvoice_jobs SET payment_method_snapshot='TM' WHERE id='61000000-0000-0000-0000-000000000001'; RAISE EXCEPTION 'ISSUED_MUTATION_ACCEPTED'; EXCEPTION WHEN others THEN IF SQLERRM<>'MEINVOICE_ISSUED_SNAPSHOT_IMMUTABLE' THEN RAISE; END IF; END; END $$;
-- Real owned batch function: guard restaurant approvals but preserve Photo's service contract.
INSERT INTO meinvoice_jobs(id,order_id,source_system,created_at,tax_entity_id,payment_method_snapshot,line_items_snapshot,payment_summary,snapshot_version)
VALUES('61000000-0000-0000-0000-000000000002','30000000-0000-0000-0000-000000000002','photo_objet_moers',now(),'10000000-0000-0000-0000-000000000001','TM','[{"display_name":"Dịch vụ chụp ảnh","quantity":1}]','{}',1),
('61000000-0000-0000-0000-000000000003','30000000-0000-0000-0000-000000000003','restaurant_pos',now(),'10000000-0000-0000-0000-000000000001','Ví điện tử/QR','[{"display_name":"Dịch vụ ăn uống"}]','{}',1);
SET request.jwt.claim.role='service_role';
SELECT fixture_assert((SELECT count(*)=1 AND bool_and(source_system='photo_objet_moers') FROM claim_meinvoice_jobs('71000000-0000-0000-0000-000000000001',50,null)),'owned claim retains Photo and blocks unapproved restaurant snapshots');
SET request.jwt.claim.role='authenticated';
SELECT fixture_assert(misa_payment_code_for_methods(ARRAY['ATM'])='Thẻ ATM' AND misa_payment_code_for_methods(ARRAY['CREDITCARD','EPAY'])='Thẻ quốc tế/Ví điện tử' AND misa_payment_code_for_methods(ARRAY['CASH'])='TM' AND misa_payment_code_for_methods(ARRAY['CREDITCARD'])='Thẻ quốc tế' AND misa_payment_code_for_methods(ARRAY['EPAY'])='Ví điện tử' AND misa_payment_code_for_methods(ARRAY['CASH','BANKTRANSFER'])='TM/CK' AND misa_payment_code_for_methods(ARRAY['QR'])='UNMAPPED','payment methods and ambiguous QR');
INSERT INTO photo_objet_sales_raw VALUES('PHOTO-FIXTURE','20000000-0000-0000-0000-000000000002','2026-10-08 15:00+07',108000,'2026-10-08',2,'PHOTO-1');
INSERT INTO photo_objet_sales_pull_runs VALUES('20000000-0000-0000-0000-000000000002','2026-10-08','excel','success'),('20000000-0000-0000-0000-000000000002','2026-10-08','excel','success');
INSERT INTO payments(order_id,restaurant_id,created_at,amount_portion,amount,method,is_revenue) VALUES('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','2026-10-08 17:00+07',200000,300000,'CASH',true),('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','2026-10-08 17:00+07',100000,300000,'BANKTRANSFER',true);
DO $$DECLARE r jsonb; BEGIN
 SELECT e INTO r FROM jsonb_array_elements(get_pos_daily_sales_summary('2026-10-08')->'entities')e WHERE e->>'tax_entity_id'='10000000-0000-0000-0000-000000000001';
 PERFORM fixture_assert((r->>'restaurant_cash')::numeric=200000 AND (r->>'restaurant_bank_transfer')::numeric=539560 AND (r->>'photo_gross')::numeric=108000,'deposit cash portions exclude transfer');
 PERFORM fixture_assert((r->>'photo_complete')::boolean,'repeated Photo imports do not duplicate store counts');
END $$;
DELETE FROM photo_objet_sales_pull_runs;
SELECT fixture_assert(NOT(SELECT (e->>'photo_complete')::boolean FROM jsonb_array_elements(get_pos_daily_sales_summary('2026-10-08')->'entities') e
 WHERE e->>'tax_entity_id'='10000000-0000-0000-0000-000000000001'),'missing Photo import remains unknown');
INSERT INTO restaurant_daily_sales_finalizations VALUES('2026-10-08','failed',null);
DO $$BEGIN BEGIN PERFORM get_pos_daily_sales_export_page('2026-10-08','10000000-0000-0000-0000-000000000001','restaurant_pos');RAISE EXCEPTION 'INTEGRITY_GATE_BYPASSED';EXCEPTION WHEN others THEN IF SQLERRM<>'RESTAURANT_EXPORT_DATA_INTEGRITY_FAILED' THEN RAISE; END IF;END; END $$;
DELETE FROM restaurant_daily_sales_finalizations WHERE business_date='2026-10-08';
INSERT INTO orders SELECT md5('page-order-'||i)::uuid,'completed','dine_in' FROM generate_series(1,205)i;
INSERT INTO payments(order_id,restaurant_id,created_at,amount_portion,amount,method,is_revenue) SELECT md5('page-order-'||i)::uuid,'20000000-0000-0000-0000-000000000001','2026-10-09 12:00+07',439560,439560,'CASH',true FROM generate_series(1,205)i;
INSERT INTO order_items(id,order_id,menu_item_id,display_name,quantity,unit_price,total_amount_ex_tax,vat_rate,vat_amount,paying_amount_inc_tax,created_at,status,item_type)
SELECT md5('page-item-'||i||'-'||item.id)::uuid,md5('page-order-'||i)::uuid,item.menu_item_id,item.display_name,item.quantity,item.unit_price,item.total_amount_ex_tax,item.vat_rate,item.vat_amount,item.paying_amount_inc_tax,'2026-10-09 11:00+07','served','menu_item'
FROM generate_series(1,205)i CROSS JOIN order_items item WHERE item.order_id='31000000-0000-0000-0000-000000000001';
DO $$DECLARE first jsonb;second jsonb;third jsonb;last jsonb;started timestamptz:=clock_timestamp(); BEGIN
 first:=get_pos_daily_sales_export_page('2026-10-09','10000000-0000-0000-0000-000000000001','restaurant_pos');last:=first->'rows'->99;
 second:=get_pos_daily_sales_export_page('2026-10-09','10000000-0000-0000-0000-000000000001','restaurant_pos',(last->>'sold_at')::timestamptz,last->>'receipt_id');last:=second->'rows'->99;
 third:=get_pos_daily_sales_export_page('2026-10-09','10000000-0000-0000-0000-000000000001','restaurant_pos',(last->>'sold_at')::timestamptz,last->>'receipt_id');
 PERFORM fixture_assert(jsonb_array_length(first->'rows')=100 AND jsonb_array_length(second->'rows')=100 AND jsonb_array_length(third->'rows')=5,'keyset pages bounded 100/100/5');
 PERFORM fixture_assert((SELECT count(DISTINCT v->>'receipt_id')=205 FROM jsonb_array_elements((first->'rows')||(second->'rows')||(third->'rows'))v),'equal timestamps have no missing or duplicate receipt');
 RAISE NOTICE 'PAGE_METRICS source_receipts=205 source_item_rows=1845 calls=3 max_response_rows=100 first_page_bytes=% total_response_bytes=% elapsed_ms=%',octet_length(first::text),octet_length(first::text)+octet_length(second::text)+octet_length(third::text),round(extract(epoch FROM clock_timestamp()-started)*1000,2);
END $$;
SET fixture.super_admin='false';
DO $$BEGIN BEGIN PERFORM get_pos_daily_sales_summary('2026-10-08');RAISE EXCEPTION 'ACCESS_GATE_BYPASSED';EXCEPTION WHEN others THEN IF SQLERRM<>'SUPER_ADMIN_ONLY' THEN RAISE; END IF;END; END $$;
