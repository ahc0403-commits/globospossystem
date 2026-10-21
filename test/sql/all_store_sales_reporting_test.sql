SET fixture.super_admin='true';
SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
INSERT INTO restaurants(id,name,brand_id,tax_entity_id,is_active,created_at) VALUES
 ('26000000-0000-0000-0000-000000000001','New brand restaurant','26000000-0000-0000-0000-000000000099','10000000-0000-0000-0000-000000000001',true,'2026-10-17 10:00+07'),
 ('26000000-0000-0000-0000-000000000002','New store without sales',NULL,'10000000-0000-0000-0000-000000000001',true,'2026-10-17 10:00+07'),
 ('26000000-0000-0000-0000-000000000003','Registered after report day',NULL,'10000000-0000-0000-0000-000000000001',true,'2026-10-19 10:00+07');
INSERT INTO orders VALUES('36000000-0000-0000-0000-000000000001','completed','dine_in');
INSERT INTO payments(order_id,restaurant_id,created_at,amount_portion,amount,method,is_revenue) VALUES
 ('36000000-0000-0000-0000-000000000001','26000000-0000-0000-0000-000000000001','2026-10-18 10:00+07',10800,21600,'CASH',true),
 ('36000000-0000-0000-0000-000000000001','26000000-0000-0000-0000-000000000001','2026-10-18 10:00+07',10800,21600,'BANKTRANSFER',true),
 ('36000000-0000-0000-0000-000000000001','26000000-0000-0000-0000-000000000001','2026-10-18 10:00+07',999999,999999,'OTHER',false);
INSERT INTO order_items(id,order_id,item_type,display_name,quantity,unit_price,total_amount_ex_tax,vat_rate,vat_amount,paying_amount_inc_tax,created_at,status,is_service_item) VALUES
 ('46000000-0000-0000-0000-000000000001','36000000-0000-0000-0000-000000000001','wet_tissue_charge','Khăn ướt',4,5000,20000,8,1600,21600,'2026-10-18 09:00+07','served',false);
DO $$DECLARE report jsonb; e jsonb; store jsonb; BEGIN
 report:=get_pos_daily_sales_summary('2026-10-18',false);
 SELECT x INTO e FROM jsonb_array_elements(report->'entities') x WHERE x->>'tax_entity_id'='10000000-0000-0000-0000-000000000001';
 SELECT x INTO store FROM jsonb_array_elements(e->'restaurant_stores') x WHERE x->>'store_id'='26000000-0000-0000-0000-000000000001';
 PERFORM fixture_assert((store->>'receipt_count')::int=1 AND (store->>'gross')::numeric=21600,'new brand automatically appears with one paid-order receipt');
 PERFORM fixture_assert((store->>'cash')::numeric=10800 AND (store->>'bank_transfer')::numeric=10800 AND (store->>'other_payments')::numeric=0,'split payments counted by portion and non-revenue excluded');
 PERFORM fixture_assert((store->>'supply')::numeric=20000 AND (store->>'vat')::numeric=1600 AND (store->>'missing_mapping_count')::int=1,'wet tissue mapping missing is visible without blocking summary');
 PERFORM fixture_assert(store->>'closing_status'='pending' AND NOT (store->>'policy_ready')::boolean,'new-store closing and policy readiness visible');
 PERFORM fixture_assert(EXISTS(SELECT 1 FROM jsonb_array_elements(e->'bunsik_stores') x WHERE x->>'store_id'='26000000-0000-0000-0000-000000000001'),'closing picker automatically includes other brands');
 PERFORM fixture_assert(EXISTS(SELECT 1 FROM jsonb_array_elements(e->'restaurant_stores') x WHERE x->>'store_id'='26000000-0000-0000-0000-000000000002' AND x->>'closing_status'='no_sales'),'registered no-sales store visible');
 PERFORM fixture_assert(NOT EXISTS(SELECT 1 FROM jsonb_array_elements(e->'bunsik_stores') x WHERE x->>'store_id'='26000000-0000-0000-0000-000000000002'),'no-sales store does not block daily cash close');
 PERFORM fixture_assert(NOT EXISTS(SELECT 1 FROM jsonb_array_elements(e->'restaurant_stores') x WHERE x->>'store_id'='26000000-0000-0000-0000-000000000003'),'future registration does not alter historical store scope');
 PERFORM fixture_assert((SELECT jsonb_agg(x-'export_metadata_deferred') FROM jsonb_array_elements(get_pos_daily_sales_summary('2026-10-18')->'entities') x)=(SELECT jsonb_agg(x-'export_metadata_deferred') FROM jsonb_array_elements(get_pos_daily_sales_summary('2026-10-18',true)->'entities') x),'both metadata overloads remain equivalent');
END $$;
-- Disabling or transferring a store must preserve the original sales seller.
UPDATE restaurants SET is_active=false,tax_entity_id='19000000-0000-0000-0000-000000000001' WHERE id='26000000-0000-0000-0000-000000000001';
INSERT INTO store_tax_entity_history(store_id,tax_entity_id,effective_from,effective_to,created_at) VALUES
 ('26000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','2026-10-17 00:00+07','2026-10-19 00:00+07',now());
DO $$DECLARE e jsonb; BEGIN
 SELECT x INTO e FROM jsonb_array_elements(get_pos_daily_sales_summary('2026-10-18',false)->'entities') x WHERE x->>'tax_entity_id'='10000000-0000-0000-0000-000000000001';
 PERFORM fixture_assert(EXISTS(SELECT 1 FROM jsonb_array_elements(e->'restaurant_stores') x WHERE x->>'store_id'='26000000-0000-0000-0000-000000000001' AND (x->>'cash')::numeric=10800),'inactive transferred store preserves historical revenue and cash');
END $$;
SET fixture.super_admin='false';
DO $$ BEGIN
 BEGIN PERFORM get_pos_daily_sales_summary('2026-10-18',false); RAISE EXCEPTION 'SUMMARY_SCOPE_BYPASSED'; EXCEPTION WHEN others THEN IF SQLERRM<>'SUPER_ADMIN_ONLY' THEN RAISE; END IF; END;
END $$;
SET fixture.super_admin='true';
