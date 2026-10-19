-- Synthetic data in the owned disposable database only.
SET fixture.super_admin='true';
SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
SELECT fixture_assert((SELECT bool_and(misa_payment_kind_for_methods(ARRAY[method])=kind
 AND misa_payment_code_for_methods(ARRAY[method])=label) FROM fixture_invoice_payment_expectations),
 'all 13 payment aliases agree with the independent contract');
SELECT fixture_assert((SELECT bool_and(misa_payment_kind_for_methods(ARRAY[a.method,b.method])='MIXED'
 AND misa_payment_code_for_methods(ARRAY[a.method,b.method])=CASE WHEN ARRAY[a.method,b.method]=ARRAY['BANKTRANSFER','CASH'] THEN 'TM/CK'
 ELSE (SELECT string_agg(label,'/' ORDER BY label COLLATE "C") FROM (SELECT DISTINCT unnest(ARRAY[a.label,b.label]) label) labels) END)
 FROM fixture_invoice_payment_expectations a JOIN fixture_invoice_payment_expectations b ON a.method<b.method),
 'all 78 distinct method pairs preserve meaning and ordering');
SELECT fixture_assert(misa_payment_code_for_methods(ARRAY['QR'])='UNMAPPED'
 AND misa_payment_code_for_methods(ARRAY['CASH','QR'])='UNMAPPED'
 AND misa_payment_code_for_methods(ARRAY['SERVICE'])='UNMAPPED'
 AND misa_payment_kind_for_methods(NULL)='UNMAPPED'
 AND misa_payment_code_for_methods(ARRAY[NULL::text])='UNMAPPED', 'unknown methods never become wallets');

CREATE TEMP TABLE contact_payment_cases AS
 SELECT md5('contact-order-'||method||'-'||mixed)::uuid id,method,kind,label,mixed
 FROM fixture_invoice_payment_expectations CROSS JOIN (VALUES(false),(true)) flags(mixed)
 WHERE method IN('MOMO','ZALOPAY','VNPAY','SHOPEEPAY','VOUCHER','CREDITSALE');
INSERT INTO orders SELECT id,'completed','dine_in' FROM contact_payment_cases;
INSERT INTO payments(order_id,restaurant_id,created_at,amount_portion,amount,method,is_revenue)
 SELECT id,'20000000-0000-0000-0000-000000000001','2026-10-10 12:00+07',CASE WHEN mixed THEN 395604 ELSE 439560 END,439560,method,true FROM contact_payment_cases;
INSERT INTO payments(order_id,restaurant_id,created_at,amount_portion,amount,method,is_revenue)
 SELECT id,'20000000-0000-0000-0000-000000000001','2026-10-10 12:00+07',43956,439560,'CASH',true FROM contact_payment_cases WHERE mixed;
INSERT INTO order_items(id,order_id,menu_item_id,display_name,quantity,unit_price,total_amount_ex_tax,vat_rate,vat_amount,paying_amount_inc_tax,created_at,status,item_type)
 SELECT md5('contact-item-'||c.id||'-'||item.id)::uuid,c.id,item.menu_item_id,item.display_name,item.quantity,item.unit_price,item.total_amount_ex_tax,item.vat_rate,item.vat_amount,item.paying_amount_inc_tax,'2026-10-10 11:00+07','served','menu_item'
 FROM contact_payment_cases c CROSS JOIN order_items item WHERE item.order_id='31000000-0000-0000-0000-000000000001';
SELECT fixture_assert((SELECT count(*)=12 AND bool_and(r.payment_code=CASE WHEN c.mixed THEN 'MIXED' ELSE c.kind END
 AND r.payment_method=misa_payment_code_for_methods(CASE WHEN c.mixed THEN ARRAY['CASH',c.method] ELSE ARRAY[c.method] END)
 AND jsonb_array_length(r.line_items)=9 AND r.gross_sales=439560
 AND (SELECT sum((x->>'quantity')::numeric)=10 AND sum((x->>'total_amount_ex_tax')::numeric)=406000 AND sum((x->>'vat_amount')::numeric)=33560 FROM jsonb_array_elements(r.line_items)x)
 AND (SELECT bool_or(x->>'menu_item_id'=md5('fixture-menu-1')::uuid::text AND x->>'vat_rate'='10')
 AND bool_or(x->>'menu_item_id'=md5('fixture-menu-2')::uuid::text AND x->>'vat_rate'='8') FROM jsonb_array_elements(r.line_items)x))
 FROM pos_restaurant_receipt_rows_v2('2026-10-10')r JOIN contact_payment_cases c ON r.receipt_id=c.id::text),
 'six added methods and six cash mixes retain amounts, quantities and beverage VAT');
SELECT fixture_assert((SELECT (e->>'restaurant_cash')::numeric=6*43956 AND (e->>'restaurant_bank_transfer')::numeric=0
 FROM jsonb_array_elements(get_pos_daily_sales_summary('2026-10-10')->'entities')e WHERE e->>'tax_entity_id'='10000000-0000-0000-0000-000000000001'),
 'Voucher, Credit Sale and gateway amounts are excluded from next-day cash deposits');

INSERT INTO meinvoice_jobs(id,order_id,source_system,created_at,tax_entity_id,payment_method_snapshot,line_items_snapshot,payment_summary,buyer_snapshot,snapshot_version)
 SELECT md5('contact-job')::uuid,c.id,'restaurant_pos',now(),'10000000-0000-0000-0000-000000000001',r.payment_method,r.line_items,
 jsonb_build_object('methods',r.payment_methods),' {"email":"fixture@example.com","phone":"0123456789","unit_name":"Bán cho người tiêu dùng"}',2
 FROM contact_payment_cases c JOIN pos_restaurant_receipt_rows_v2('2026-10-10')r ON r.receipt_id=c.id::text WHERE c.method='MOMO' AND NOT c.mixed;
SELECT fixture_assert((SELECT NOT is_red_invoice AND buyer_email='fixture@example.com' AND buyer_phone='0123456789'
 FROM pos_restaurant_receipt_rows_v2('2026-10-10',ARRAY[md5('contact-order-MOMO-false')::uuid])),
 'ordinary receipt contacts fall back to the recorded job snapshot');
CREATE TEMP TABLE original_contact_hash AS SELECT source_hash FROM pos_restaurant_receipt_rows_v2('2026-10-10',ARRAY[md5('contact-order-MOMO-false')::uuid]);
INSERT INTO red_invoice_intakes(id,order_id,status,buyer_email,buyer_phone)
 VALUES(md5('contact-intake')::uuid,md5('contact-order-MOMO-false')::uuid,'cancelled','updated@example.com','0987654321');
SELECT fixture_assert((SELECT NOT is_red_invoice AND buyer_email='updated@example.com' AND buyer_phone='0987654321'
 FROM pos_restaurant_receipt_rows_v2('2026-10-10',ARRAY[md5('contact-order-MOMO-false')::uuid])),
 'contacts from an ordinary intake survive without requiring a red invoice');
SELECT fixture_assert((SELECT r.source_hash<>h.source_hash FROM pos_restaurant_receipt_rows_v2('2026-10-10',ARRAY[md5('contact-order-MOMO-false')::uuid])r CROSS JOIN original_contact_hash h),
 'contact changes are included in the exported source hash');
SELECT fixture_assert(refresh_meinvoice_export_snapshots('2026-10-10','10000000-0000-0000-0000-000000000001',ARRAY[md5('contact-order-MOMO-false')::uuid])=1,
 'pending contact edit refreshes one snapshot');
SELECT fixture_assert((SELECT snapshot_version=3 AND buyer_snapshot->>'email'='updated@example.com' AND buyer_snapshot->>'phone'='0987654321'
 FROM meinvoice_jobs WHERE id=md5('contact-job')::uuid)
 AND (SELECT buyer_snapshot->>'email'='fixture@example.com' AND buyer_snapshot->>'phone'='0123456789'
 FROM meinvoice_job_snapshot_versions WHERE job_id=md5('contact-job')::uuid AND snapshot_version=2), 'original contacts archived with the snapshot version');
SELECT fixture_assert(refresh_meinvoice_export_snapshots('2026-10-10','10000000-0000-0000-0000-000000000001',ARRAY[md5('contact-order-MOMO-false')::uuid])=0,
 'an unchanged refresh does not create another version');
UPDATE red_invoice_intakes SET buyer_email='',buyer_phone='0123456789' WHERE id=md5('contact-intake')::uuid;
SELECT fixture_assert(refresh_meinvoice_export_snapshots('2026-10-10','10000000-0000-0000-0000-000000000001',ARRAY[md5('contact-order-MOMO-false')::uuid])=1, 'contact clear refreshes one snapshot');
SELECT fixture_assert((SELECT buyer_snapshot->>'email'='' AND buyer_snapshot->>'phone'='0123456789' AND snapshot_version=4 FROM meinvoice_jobs WHERE id=md5('contact-job')::uuid),
 'explicitly cleared email is not resurrected from an earlier snapshot');
UPDATE meinvoice_jobs SET status='valid_invoice',invoice_number='FIXTURE-CONTACT-ISSUED' WHERE id=md5('contact-job')::uuid;
UPDATE red_invoice_intakes SET buyer_email='later@example.com',buyer_phone='0999999999' WHERE id=md5('contact-intake')::uuid;
SELECT fixture_assert((SELECT buyer_email='' AND buyer_phone='0123456789' FROM pos_restaurant_receipt_rows_v2('2026-10-10',ARRAY[md5('contact-order-MOMO-false')::uuid])),
 'issued export retains the original contact snapshot');
DO $$BEGIN BEGIN UPDATE meinvoice_jobs SET buyer_snapshot=buyer_snapshot||'{"email":"mutated@example.com"}' WHERE id=md5('contact-job')::uuid;
 RAISE EXCEPTION 'ISSUED_CONTACT_MUTATION_ACCEPTED'; EXCEPTION WHEN others THEN IF SQLERRM<>'MEINVOICE_ISSUED_SNAPSHOT_IMMUTABLE' THEN RAISE; END IF; END; END $$;
SELECT fixture_assert(refresh_meinvoice_export_snapshots('2026-10-10','10000000-0000-0000-0000-000000000001',ARRAY[md5('contact-order-MOMO-false')::uuid])=0,
 'issued jobs are excluded from refresh');
INSERT INTO meinvoice_jobs(id,order_id,source_system,created_at,tax_entity_id,payment_method_snapshot,line_items_snapshot,payment_summary,buyer_snapshot,snapshot_version,dispatch_claim_id)
 SELECT md5('claimed-contact-job')::uuid,c.id,'restaurant_pos',now(),'10000000-0000-0000-0000-000000000001',r.payment_method,r.line_items,
 jsonb_build_object('methods',r.payment_methods),'{"email":"claimed@example.com","phone":"0123456789"}',2,md5('claimed-contact-batch')::uuid
 FROM contact_payment_cases c JOIN pos_restaurant_receipt_rows_v2('2026-10-10')r ON r.receipt_id=c.id::text WHERE c.method='ZALOPAY' AND NOT c.mixed;
INSERT INTO red_invoice_intakes(id,order_id,status,buyer_email,buyer_phone)
 VALUES(md5('claimed-contact-intake')::uuid,md5('contact-order-ZALOPAY-false')::uuid,'cancelled','later@example.com','0999999999');
SELECT fixture_assert((SELECT buyer_email='claimed@example.com' AND buyer_phone='0123456789' FROM pos_restaurant_receipt_rows_v2('2026-10-10',ARRAY[md5('contact-order-ZALOPAY-false')::uuid])),
 'a claimed pending job also keeps its contact snapshot');
SELECT fixture_assert(refresh_meinvoice_export_snapshots('2026-10-10','10000000-0000-0000-0000-000000000001',ARRAY[md5('contact-order-ZALOPAY-false')::uuid])=0,
 'claimed jobs are excluded from refresh');
DO $$BEGIN BEGIN UPDATE meinvoice_jobs SET buyer_snapshot=buyer_snapshot||'{"phone":"0999999999"}' WHERE id=md5('claimed-contact-job')::uuid;
 RAISE EXCEPTION 'CLAIMED_CONTACT_MUTATION_ACCEPTED'; EXCEPTION WHEN others THEN IF SQLERRM<>'MEINVOICE_ISSUED_SNAPSHOT_IMMUTABLE' THEN RAISE; END IF; END; END $$;
SELECT fixture_assert(misa_buyer_contact_snapshot(NULL,NULL,NULL,'{"email":"  fixture@example.com  ","phone":"0123456789"}',false)
 ='{"email":"fixture@example.com","phone":"0123456789"}'::jsonb
 AND misa_buyer_contact_snapshot(md5('intake')::uuid,NULL,NULL,'{"email":"old@example.com"}',false)='{"email":"","phone":""}'::jsonb,
 'optional contacts stay empty and phone numbers stay text');
SET fixture.super_admin='false';
DO $$BEGIN BEGIN PERFORM refresh_meinvoice_export_snapshots('2026-10-10','10000000-0000-0000-0000-000000000001',ARRAY[md5('contact-order-MOMO-false')::uuid]);
 RAISE EXCEPTION 'CONTACT_ACCESS_GATE_BYPASSED'; EXCEPTION WHEN others THEN IF SQLERRM<>'SUPER_ADMIN_ONLY' THEN RAISE; END IF; END; END $$;
