SET fixture.super_admin='true';
SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
CREATE TEMP TABLE deposit_bank_baseline AS
SELECT COALESCE((e->>'restaurant_bank_transfer')::numeric,0) amount
FROM jsonb_array_elements(get_pos_daily_sales_summary('2026-10-12')->'entities') e
WHERE e->>'tax_entity_id'='10000000-0000-0000-0000-000000000001';
DO $$DECLARE lean jsonb; full_data jsonb; lean_row jsonb; full_row jsonb; before_hash text; after_hash text; item_id uuid;BEGIN
 lean:=get_pos_daily_sales_summary('2026-10-08',false);
 full_data:=get_pos_daily_sales_summary('2026-10-08',true);
 FOR lean_row IN SELECT value FROM jsonb_array_elements(lean->'entities') LOOP
  SELECT value INTO full_row FROM jsonb_array_elements(full_data->'entities') WHERE value->>'tax_entity_id'=lean_row->>'tax_entity_id';
  PERFORM fixture_assert(lean_row->'source_revision'='null'::jsonb AND (lean_row->>'export_metadata_deferred')::boolean
   AND (lean_row-'source_revision'-'export_metadata_deferred')=(full_row-'source_revision'-'export_metadata_deferred'),'deferred summary preserves every financial amount and state');
 END LOOP;
 SELECT i.id INTO item_id FROM order_items i JOIN pos_daily_receipt_scope('2026-10-08') s ON s.order_id=i.order_id WHERE s.tax_entity_id='10000000-0000-0000-0000-000000000001' LIMIT 1;
 before_hash:=pos_sales_export_source_revision('2026-10-08','10000000-0000-0000-0000-000000000001');
 UPDATE order_items SET quantity=quantity+1 WHERE id=item_id;
 after_hash:=pos_sales_export_source_revision('2026-10-08','10000000-0000-0000-0000-000000000001');
 PERFORM fixture_assert(before_hash<>after_hash,'v3 fingerprint catches same-gross quantity edit');
 UPDATE order_items SET quantity=quantity-1 WHERE id=item_id;
 PERFORM fixture_assert(before_hash=pos_sales_export_source_revision('2026-10-08','10000000-0000-0000-0000-000000000001'),'v3 fingerprint stable after restoring same source');
 PERFORM fixture_assert(get_pos_daily_sales_export_page('2026-10-08','10000000-0000-0000-0000-000000000001','restaurant_pos')->>'source_revision_version'='3','export page explicitly identifies fingerprint version');
END $$;
UPDATE restaurants SET brand_id='a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878' WHERE id='20000000-0000-0000-0000-000000000001';
INSERT INTO tax_entity_collection_accounts(tax_entity_id,bank_bin,bank_label,account_number,account_holder)
VALUES('10000000-0000-0000-0000-000000000001','970426','MSB','80002014298','AKJ INTERNATIONAL CO., LTD');
INSERT INTO orders VALUES('35000000-0000-0000-0000-000000000001','completed','dine_in');
INSERT INTO payments(order_id,restaurant_id,created_at,amount_portion,amount,method,is_revenue)
VALUES('35000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','2026-10-12 12:00+07',2000000,5000000,'CASH',true),
('35000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','2026-10-12 12:00+07',3000000,5000000,'BANKTRANSFER',true);
INSERT INTO photo_objet_sales_raw VALUES('DEPOSIT-PHOTO','20000000-0000-0000-0000-000000000002','2026-10-12 12:00+07',10000000,'2026-10-12',2,'PHOTO');
INSERT INTO direct_order_driver_cash_movements(restaurant_id,kind,method,amount,occurred_at) VALUES
('20000000-0000-0000-0000-000000000001','payout','CASH',150000,'2026-10-12 12:00+07'),
('20000000-0000-0000-0000-000000000001','recovery','CASH',50000,'2026-10-12 12:00+07'),
('20000000-0000-0000-0000-000000000001','recovery','BANKTRANSFER',999000,'2026-10-12 12:00+07');
INSERT INTO direct_order_refund_records VALUES('75000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',100000,'2026-10-12 12:00+07');
INSERT INTO direct_order_refund_evidence VALUES('75000000-0000-0000-0000-000000000001','CASH'),('75000000-0000-0000-0000-000000000001','CASH');
CREATE FUNCTION fixture_deposit_row(day date) RETURNS jsonb LANGUAGE sql AS $$
 SELECT e FROM jsonb_array_elements(get_pos_daily_sales_summary(day)->'entities') e WHERE e->>'tax_entity_id'='10000000-0000-0000-0000-000000000001'
$$;
SELECT fixture_assert((fixture_deposit_row('2026-10-12')->>'restaurant_bank_transfer')::numeric=3000000+COALESCE((SELECT amount FROM deposit_bank_baseline),0),'mixed transfer portion remains separate');
SELECT fixture_assert(fixture_deposit_row('2026-10-12')->'bunsik_closed_deposit'='null'::jsonb,'unclosed cash is unknown, not zero');
SELECT fixture_assert((fixture_deposit_row('2026-10-12')->>'bunsik_expected_deposit')::numeric=1800000,'expected cash applies movements once');
SELECT fixture_assert(NOT(fixture_deposit_row('2026-10-12')->>'photo_complete')::boolean,'missing Photo import distinct from zero');
SELECT fixture_assert((get_daily_closing_deposit_days('20000000-0000-0000-0000-000000000001',30,'2026-10-12')->0->>'direct_order_cash_refunds')::numeric=100000
 AND (get_daily_closing_deposit_days('20000000-0000-0000-0000-000000000001',30,'2026-10-12')->0->>'delivery_cash_recovered')::numeric=50000,'unclosed history shares deduplicated cash adjustments');
SELECT fixture_assert((get_daily_closing_deposit_days('20000000-0000-0000-0000-000000000001',30,'2026-10-12')->0->>'expected_cash_amount')::numeric=6800000,'exact-day history uses selected-day cash instead of current-day bounds');
DO $$DECLARE r jsonb; BEGIN
 r:=get_daily_closing_cash_preview('20000000-0000-0000-0000-000000000001','2026-10-12');
 PERFORM fixture_assert((r->>'expected_cash_amount')::numeric=6800000 AND (r->>'direct_order_cash_refunds')::numeric=100000 AND (r->>'delivery_cash_recovered')::numeric=50000,'preview correct and duplicate refund evidence deduplicated');
 PERFORM fixture_assert(r->>'deposit_date'='2026-10-13' AND r->'bank'->>'account_number'='80002014298','preview has next day and legal bank');
 r:=create_daily_closing('20000000-0000-0000-0000-000000000001',NULL,'{"500000":13,"50000":5}',5000000,'2026-10-12');
 PERFORM fixture_assert((r->>'deposit_amount')::numeric=1750000 AND (r->>'cash_variance')::numeric=-50000,'actual deposit is counted cash minus float');
END $$;
SELECT fixture_assert((fixture_deposit_row('2026-10-12')->>'bunsik_closed_deposit')::numeric=1750000
 AND (fixture_deposit_row('2026-10-12')->>'bunsik_closed_store_count')::int=1,'cash confirmed even while Photo is missing');
INSERT INTO photo_objet_sales_pull_runs VALUES('20000000-0000-0000-0000-000000000002','2026-10-12','excel','success'),('20000000-0000-0000-0000-000000000002','2026-10-12','excel','success');
SELECT fixture_assert((fixture_deposit_row('2026-10-12')->>'photo_complete')::boolean
 AND (fixture_deposit_row('2026-10-12')->>'photo_gross')::numeric=10000000
 AND (fixture_deposit_row('2026-10-12')->>'bunsik_variance_store_count')::int=1,'Photo known, no duplicate imports, closing variance independent');
SELECT fixture_assert((SELECT bool_and(r.source_revision=pos_sales_export_source_revision('2026-10-12',r.tax_entity_id))
 FROM pos_sales_export_source_revisions('2026-10-12') r),'bulk fingerprints equal scoped export fingerprints');
SELECT fixture_assert(jsonb_array_length(get_daily_closing_deposit_days('20000000-0000-0000-0000-000000000001',30,'2026-10-12'))=1
 AND get_daily_closing_deposit_days('20000000-0000-0000-0000-000000000001',30,'2026-10-12')->0->>'deposit_date'='2026-10-13'
 AND NOT(get_daily_closing_deposit_days('20000000-0000-0000-0000-000000000001',30,'2026-10-12')->0->>'cash_ledger_changed')::boolean,'exact-day history bounded and stable snapshot stays unchanged');
INSERT INTO payments(order_id,restaurant_id,created_at,amount_portion,amount,method,is_revenue)
VALUES('35000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','2026-10-12 15:00+07',1000,1000,'CASH',true);
SELECT fixture_assert((fixture_deposit_row('2026-10-12')->>'bunsik_late_ledger_store_count')::int=1
 AND (fixture_deposit_row('2026-10-12')->>'bunsik_closed_deposit')::numeric=1750000,'late ledger warns without rewriting closing');
SELECT fixture_assert((get_daily_closing_deposit_days('20000000-0000-0000-0000-000000000001',30,'2026-10-12')->0->>'cash_ledger_changed')::boolean,'closing detail detects cash ledger changes without changing snapshot');
INSERT INTO restaurants(id,name,brand_id,tax_entity_id,is_active)
VALUES('25000000-0000-0000-0000-000000000002','Second Bunsik','a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878','10000000-0000-0000-0000-000000000001',true),
('25000000-0000-0000-0000-000000000003','Other restaurant',NULL,'10000000-0000-0000-0000-000000000001',true);
SELECT fixture_assert((fixture_deposit_row('2026-10-12')->>'bunsik_store_count')::int=2
 AND (fixture_deposit_row('2026-10-12')->>'bunsik_closed_store_count')::int=1,'partial closing excludes other brands');
SELECT create_daily_closing('25000000-0000-0000-0000-000000000002',NULL,'{"500000":8}',5000000,'2026-10-12');
SELECT fixture_assert((fixture_deposit_row('2026-10-12')->>'bunsik_shortfall_store_count')::int=1,'float shortage not silently clamped');
INSERT INTO photo_objet_sales_pull_runs VALUES('20000000-0000-0000-0000-000000000002','2026-10-11','excel','success');
SELECT fixture_assert((fixture_deposit_row('2026-10-11')->>'photo_complete')::boolean AND (fixture_deposit_row('2026-10-11')->>'photo_gross')::numeric=0,'confirmed zero distinct from missing Photo');
SET fixture.super_admin='false';
DO $$ BEGIN
 BEGIN PERFORM get_pos_daily_sales_summary('2026-10-12'); RAISE EXCEPTION 'SUMMARY_SCOPE_BYPASSED'; EXCEPTION WHEN others THEN IF SQLERRM<>'SUPER_ADMIN_ONLY' THEN RAISE; END IF; END;
 BEGIN PERFORM get_pos_daily_sales_summary('2026-10-12',false); RAISE EXCEPTION 'SUMMARY_SCOPE_BYPASSED'; EXCEPTION WHEN others THEN IF SQLERRM<>'SUPER_ADMIN_ONLY' THEN RAISE; END IF; END;
 BEGIN PERFORM get_daily_closing_deposit_days('25000000-0000-0000-0000-000000000002',1,'2026-10-12'); RAISE EXCEPTION 'CLOSING_SCOPE_BYPASSED'; EXCEPTION WHEN others THEN IF SQLERRM<>'DAILY_CLOSINGS_FORBIDDEN' THEN RAISE; END IF; END;
 PERFORM fixture_assert(jsonb_array_length(get_daily_closing_deposit_days('20000000-0000-0000-0000-000000000001',1,'2026-10-12'))=1,'authorized store history still works');
END $$;
SET fixture.super_admin='true';
SELECT fixture_assert(NOT has_function_privilege('anon','get_daily_closing_deposit_days(uuid,integer,date)','EXECUTE')
 AND NOT has_function_privilege('authenticated','pos_sales_export_source_revisions(date)','EXECUTE'),'private helpers and public role boundaries preserved');
SELECT fixture_assert((SELECT bool_and(r.source_revision=pos_sales_export_source_revision('2026-10-08',r.tax_entity_id))
 FROM pos_sales_export_source_revisions('2026-10-08') r),'fingerprints retain items, invoice jobs, contacts and Photo');
INSERT INTO payments(id,order_id,restaurant_id,created_at,amount_portion,amount,method,is_revenue)
SELECT md5('bank-page-'||i)::uuid,'35000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','2026-10-02 12:00+07',1000,5000,'BANKTRANSFER',true FROM generate_series(1,205) i;
DO $$DECLARE first jsonb;second jsonb;third jsonb;last jsonb;BEGIN
 first:=get_bank_transfer_sales_page('2026-10-02','2026-10-02','10000000-0000-0000-0000-000000000001');last:=first->'rows'->99;
 second:=get_bank_transfer_sales_page('2026-10-02','2026-10-02','10000000-0000-0000-0000-000000000001',NULL,(last->>'created_at')::timestamptz,(last->>'payment_id')::uuid);last:=second->'rows'->99;
 third:=get_bank_transfer_sales_page('2026-10-02','2026-10-02','10000000-0000-0000-0000-000000000001',NULL,(last->>'created_at')::timestamptz,(last->>'payment_id')::uuid);
 PERFORM fixture_assert(jsonb_array_length(first->'rows')=100 AND jsonb_array_length(second->'rows')=100 AND jsonb_array_length(third->'rows')=5,'bank ledger bounded 100/100/5');
 PERFORM fixture_assert((SELECT count(DISTINCT r->>'payment_id')=205 AND sum((r->>'amount')::numeric)=205000 FROM jsonb_array_elements((first->'rows')||(second->'rows')||(third->'rows')) r),'same-time transfers have no gaps, duplicates or whole-order sums');
END $$;
SET fixture.super_admin='false';
DO $$BEGIN
 BEGIN PERFORM get_bank_transfer_sales_page('2026-10-02','2026-10-02','10000000-0000-0000-0000-000000000001');RAISE EXCEPTION 'BANK_SCOPE_BYPASSED';EXCEPTION WHEN others THEN IF SQLERRM<>'BANK_TRANSFER_FORBIDDEN' THEN RAISE;END IF;END;
 BEGIN PERFORM get_bank_transfer_sales_page('2026-10-02','2026-10-02',NULL,'25000000-0000-0000-0000-000000000002');RAISE EXCEPTION 'BANK_STORE_BYPASSED';EXCEPTION WHEN others THEN IF SQLERRM<>'BANK_TRANSFER_FORBIDDEN' THEN RAISE;END IF;END;
 PERFORM fixture_assert(jsonb_array_length(get_bank_transfer_sales_page('2026-10-02','2026-10-02',NULL,'20000000-0000-0000-0000-000000000001')->'rows')=100,'authorized bank ledger bounded');
END $$;
SET fixture.super_admin='true';
