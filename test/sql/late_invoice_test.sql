SET request.jwt.claim.sub='00000000-0000-4000-8000-000000000001';
CREATE FUNCTION late_fixture.submit(n integer,request uuid DEFAULT NULL,phone text DEFAULT '') RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c jsonb;o uuid:=md5('late-order-'||n)::uuid;
BEGIN
 c:=pos_late_invoice_context(late_fixture.shop(1),o,NULL);
 RETURN pos_submit_late_invoice(coalesce(request,md5('late-submit-'||n)::uuid),late_fixture.shop(1),o,NULL,c->'versions',late_fixture.patch(phone),true);
END $$;
SELECT late_fixture.sale(1),late_fixture.sale(2),late_fixture.sale(3),late_fixture.sale(4),late_fixture.sale(5),late_fixture.sale(6),late_fixture.sale(7),late_fixture.sale(8),late_fixture.sale(9);
CREATE TABLE late_fixture.original AS SELECT jsonb_build_object('payments',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM payments p),'items',(SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM order_items i),'receipts',(SELECT jsonb_agg(to_jsonb(d) ORDER BY d.id) FROM digital_receipts d)) data;
SELECT fixture_assert(late_fixture.submit(1)->>'state'='ready','phone-free request is ready');
SELECT fixture_assert((SELECT buyer_phone IS NULL AND status='ready' AND requested_by=(SELECT id FROM users WHERE auth_id=auth.uid()) FROM red_invoice_intakes WHERE order_id=md5('late-order-1')::uuid),'optional phone and actual cashier attribution');
SELECT fixture_assert((SELECT buyer_kind='registered' AND buyer_snapshot->>'phone'='' AND status='dispatch_paused' AND dispatch_attempts=0 FROM meinvoice_jobs WHERE order_id=md5('late-order-1')::uuid),'buyer job synchronized without dispatch');
SELECT fixture_assert(pos_submit_late_invoice(md5('late-submit-1')::uuid,late_fixture.shop(1),md5('late-order-1')::uuid,NULL,jsonb_build_object(md5('late-order-1')::uuid,NULL),late_fixture.patch(),true)->>'replayed'='true','same request replay returns existing result');
SELECT fixture_assert((SELECT count(*)=1 FROM meinvoice_jobs WHERE order_id=md5('late-order-1')::uuid),'replay does not duplicate job');
DO $$BEGIN
 BEGIN PERFORM pos_submit_late_invoice(md5('late-submit-1')::uuid,late_fixture.shop(1),md5('late-order-1')::uuid,NULL,jsonb_build_object(md5('late-order-1')::uuid,NULL),late_fixture.patch('0999999999'),true); RAISE EXCEPTION 'accepted';
 EXCEPTION WHEN others THEN IF SQLERRM<>'LATE_INVOICE_REQUEST_CONFLICT' THEN RAISE; END IF; END;
 BEGIN PERFORM pos_submit_late_invoice(gen_random_uuid(),late_fixture.shop(1),md5('late-order-1')::uuid,NULL,jsonb_build_object(md5('late-order-1')::uuid,NULL),late_fixture.patch(),true); RAISE EXCEPTION 'accepted';
 EXCEPTION WHEN others THEN IF SQLERRM<>'POS_BUYER_CHANGED' THEN RAISE; END IF; END;
END $$;
INSERT INTO meinvoice_jobs(order_id,store_id,tax_entity_id,buyer_snapshot,line_items_snapshot,payment_summary)
SELECT md5('late-order-2')::uuid,late_fixture.shop(1),md5('late-tax')::uuid,'{"customer_name":"Anonymous"}','[{"display_name":"Frozen sold line","quantity":1,"total_amount_ex_tax":100000,"vat_amount":8000}]','[{"amount_portion":108000,"method":"BANKTRANSFER"}]';
CREATE TABLE late_fixture.job_original AS SELECT line_items_snapshot,payment_summary,payment_method_snapshot FROM meinvoice_jobs WHERE order_id=md5('late-order-2')::uuid;
SELECT fixture_assert(late_fixture.submit(2,NULL,'02800000000')->>'state'='ready','phone with leading zero is accepted');
SELECT fixture_assert((SELECT buyer_snapshot->>'phone'='02800000000' AND snapshot_version=3 FROM meinvoice_jobs WHERE order_id=md5('late-order-2')::uuid),'leading zero and revision preserved');
SELECT fixture_assert((SELECT count(*)=1 FROM meinvoice_job_snapshot_versions v JOIN meinvoice_jobs j ON j.id=v.job_id WHERE j.order_id=md5('late-order-2')::uuid AND v.buyer_snapshot->>'customer_name'='Anonymous'),'previous buyer snapshot archived');
SELECT fixture_assert((SELECT ROW(j.line_items_snapshot,j.payment_summary,j.payment_method_snapshot)=ROW(o.line_items_snapshot,o.payment_summary,o.payment_method_snapshot) FROM meinvoice_jobs j CROSS JOIN late_fixture.job_original o WHERE j.order_id=md5('late-order-2')::uuid),'frozen financial snapshot unchanged');
SELECT fixture_assert((SELECT data=jsonb_build_object('payments',(SELECT jsonb_agg(to_jsonb(p) ORDER BY p.id) FROM payments p),'items',(SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) FROM order_items i),'receipts',(SELECT jsonb_agg(to_jsonb(d) ORDER BY d.id) FROM digital_receipts d)) FROM late_fixture.original),'original sales tables unchanged');
-- The existing immediate-entry RPC now accepts the same phone-free buyer.
SELECT fixture_assert(pos_save_buyer_information(late_fixture.shop(1),md5('late-order-3')::uuid,NULL,late_fixture.patch(),true)->>'status'='ready','existing immediate buyer flow accepts blank phone');
SELECT fixture_assert(upsert_red_invoice_intake_minimal(md5('late-order-4')::uuid,late_fixture.shop(1),'cashier','ready','0012345678','Fixture Company','Fixture address','buyer@example.invalid',NULL,NULL)->>'status'='ready','legacy intake accepts blank phone');
-- Missing phone never weakens required company/name/address/email/number checks.
DO $$BEGIN
 BEGIN PERFORM pos_submit_late_invoice(gen_random_uuid(),late_fixture.shop(1),md5('late-order-5')::uuid,NULL,jsonb_build_object(md5('late-order-5')::uuid,NULL),late_fixture.patch()||'{"buyer_email":""}',true); RAISE EXCEPTION 'accepted';
 EXCEPTION WHEN others THEN IF SQLERRM<>'RED_INVOICE_BUYER_INFORMATION_INCOMPLETE' THEN RAISE; END IF; END;
 BEGIN PERFORM pos_submit_late_invoice(gen_random_uuid(),late_fixture.shop(1),md5('late-order-5')::uuid,NULL,jsonb_build_object(md5('late-order-5')::uuid,NULL),late_fixture.patch()||'{"buyer_number_value":"123"}',true); RAISE EXCEPTION 'accepted';
 EXCEPTION WHEN others THEN IF SQLERRM<>'POS_BUYER_NUMBER_INVALID' THEN RAISE; END IF; END;
END $$;
SELECT fixture_assert(pos_submit_late_invoice(gen_random_uuid(),late_fixture.shop(1),md5('late-order-5')::uuid,NULL,jsonb_build_object(md5('late-order-5')::uuid,NULL),'{}',false)->>'state'='draft','incomplete draft is saved');
-- Refunded, already sent/issued, external reporting, and frozen batches fail closed.
INSERT INTO payment_adjustments(payment_id,amount) SELECT id,1 FROM payments WHERE order_id=md5('late-order-6')::uuid;
INSERT INTO meinvoice_jobs(order_id,store_id,tax_entity_id,status,invoice_number) VALUES(md5('late-order-7')::uuid,late_fixture.shop(1),md5('late-tax')::uuid,'valid_invoice','FIXTURE-ISSUED');
INSERT INTO meinvoice_jobs(order_id,store_id,tax_entity_id,dispatch_attempts) VALUES(md5('late-order-8')::uuid,late_fixture.shop(1),md5('late-tax')::uuid,1);
INSERT INTO sales_reporting_batches VALUES(gen_random_uuid(),(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,md5('late-tax')::uuid,'confirmed',jsonb_build_array(jsonb_build_object('source','restaurant_pos','id',md5('late-order-9')::uuid)));
DO $$DECLARE n integer;BEGIN
 FOREACH n IN ARRAY ARRAY[6,7,8,9] LOOP
  BEGIN PERFORM late_fixture.submit(n); RAISE EXCEPTION 'accepted';
  EXCEPTION WHEN others THEN IF SQLERRM<>'LATE_INVOICE_PROTECTED' THEN RAISE; END IF; END;
 END LOOP;
END $$;
SELECT fixture_assert((pos_late_invoice_context(late_fixture.shop(1),md5('late-order-7')::uuid,NULL)->>'state')='issued','issued invoice opens status instead of fresh request');
SELECT fixture_assert((pos_late_invoice_context(late_fixture.shop(1),md5('late-order-8')::uuid,NULL)->>'state')='processing','uncertain previous dispatch is protected');
-- Historical evidence still protects a job whose retry counter was reset.
SELECT late_fixture.sale(14),late_fixture.sale(15),late_fixture.sale(16);
INSERT INTO meinvoice_jobs(order_id,store_id,tax_entity_id) VALUES(md5('late-order-14')::uuid,late_fixture.shop(1),md5('late-tax')::uuid);
INSERT INTO meinvoice_job_events SELECT id,'dispatch_outcome_unknown',1 FROM meinvoice_jobs WHERE order_id=md5('late-order-14')::uuid;
INSERT INTO einvoice_jobs VALUES(md5('late-order-15')::uuid,'https://fixture.invalid/issued','succeeded');
DO $$DECLARE n integer;BEGIN FOREACH n IN ARRAY ARRAY[14,15] LOOP
 BEGIN PERFORM late_fixture.submit(n);RAISE EXCEPTION 'accepted';EXCEPTION WHEN others THEN IF SQLERRM<>'LATE_INVOICE_PROTECTED' THEN RAISE;END IF;END;
END LOOP;END $$;
-- Missing jobs use the existing pure mixed-VAT splitter, preserving both rates.
UPDATE order_items SET vat_rate=-1,vat_amount=9000,paying_amount_inc_tax=109000,vat_breakdown='[{"vat_rate":8,"total_amount_ex_tax":50000,"vat_amount":4000,"paying_amount_inc_tax":54000},{"vat_rate":10,"total_amount_ex_tax":50000,"vat_amount":5000,"paying_amount_inc_tax":55000}]' WHERE order_id=md5('late-order-16')::uuid;
UPDATE payments SET amount=109000,amount_portion=109000 WHERE order_id=md5('late-order-16')::uuid;
SELECT late_fixture.submit(16);
SELECT fixture_assert((SELECT jsonb_array_length(line_items_snapshot)=2 AND (SELECT sum((x->>'paying_amount_inc_tax')::numeric) FROM jsonb_array_elements(line_items_snapshot)x)=109000 FROM meinvoice_jobs WHERE order_id=md5('late-order-16')::uuid),'mixed VAT expansion preserves original 8/10 percent totals');
-- Store/role checks execute even for an idempotent replay.
SET request.jwt.claim.sub='00000000-0000-4000-8000-000000000002';
DO $$BEGIN BEGIN PERFORM late_fixture.submit(1);RAISE EXCEPTION 'accepted';EXCEPTION WHEN others THEN IF SQLERRM<>'STORE_ACCESS_FORBIDDEN' THEN RAISE;END IF;END;END $$;
SET request.jwt.claim.sub='00000000-0000-4000-8000-000000000003';
DO $$BEGIN BEGIN PERFORM late_fixture.submit(1);RAISE EXCEPTION 'accepted';EXCEPTION WHEN others THEN IF SQLERRM<>'RED_INVOICE_INTAKE_FORBIDDEN' THEN RAISE;END IF;END;END $$;
SET request.jwt.claim.sub='00000000-0000-4000-8000-000000000001';
-- Combined payments and Direct Order's linked charges are updated as a set.
SELECT late_fixture.sale(10),late_fixture.sale(11),late_fixture.sale(12),late_fixture.sale(13);
INSERT INTO combined_payment_groups VALUES(md5('late-combined')::uuid,now());
UPDATE payments SET combined_payment_group_id=md5('late-combined')::uuid WHERE order_id IN(md5('late-order-10')::uuid,md5('late-order-11')::uuid);
SELECT fixture_assert(jsonb_array_length(pos_late_invoice_context(late_fixture.shop(1),md5('late-order-10')::uuid,NULL)->'order_ids')=2,'single-order anchor resolves entire combined receipt');
SELECT fixture_assert(jsonb_array_length(late_fixture.submit(10)->'order_ids')=2,'combined request saved atomically');
SELECT fixture_assert((SELECT count(*)=2 AND bool_and(buyer_kind='registered') FROM meinvoice_jobs WHERE order_id IN(md5('late-order-10')::uuid,md5('late-order-11')::uuid)),'all combined jobs synchronized');
INSERT INTO direct_order_requests(id,restaurant_id) VALUES(md5('late-direct')::uuid,late_fixture.shop(1));
INSERT INTO direct_order_financials VALUES(md5('late-order-12')::uuid,late_fixture.shop(1),md5('late-direct')::uuid);
INSERT INTO direct_order_payment_charges VALUES(md5('late-order-13')::uuid,late_fixture.shop(1),md5('late-direct')::uuid);
SELECT fixture_assert(jsonb_array_length(late_fixture.submit(12)->'order_ids')=2,'direct supplemental order set synchronized');
SELECT fixture_assert((SELECT invoice_details->>'phone'='' AND invoice_details->>'buyer_confirmed'='true' FROM direct_order_requests WHERE id=md5('late-direct')::uuid),'direct snapshot allows no phone');
INSERT INTO sales_external_reporting_protections VALUES((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,md5('late-tax')::uuid,'restaurant_pos');
DO $$BEGIN BEGIN PERFORM late_fixture.submit(3);RAISE EXCEPTION 'accepted';EXCEPTION WHEN others THEN IF SQLERRM<>'LATE_INVOICE_PROTECTED' THEN RAISE;END IF;END;END $$;
DO $$BEGIN BEGIN UPDATE meinvoice_jobs SET buyer_snapshot='{}' WHERE order_id=md5('late-order-2')::uuid;RAISE EXCEPTION 'accepted';EXCEPTION WHEN others THEN IF SQLERRM<>'MEINVOICE_EXTERNALLY_REPORTED_IMMUTABLE' THEN RAISE;END IF;END;END $$;
DELETE FROM sales_external_reporting_protections;
DELETE FROM sales_reporting_batches;
-- Exercise the actual authorized page query and its single batch annotation.
SELECT late_fixture.sale(i) FROM generate_series(100,599) i;
DO $$DECLARE started timestamptz:=clock_timestamp();p jsonb;BEGIN
 p:=get_receipt_ledger_page((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,late_fixture.shop(1),NULL,NULL,50);
 PERFORM fixture_assert(jsonb_array_length(p->'receipts')=50,'page remains bounded at 50');
 PERFORM fixture_assert(NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p->'receipts') r WHERE r->>'invoice_state' IS NULL),'batch annotation includes every page row');
 RAISE NOTICE 'LATE_INVOICE_PAGE rows=% bytes=% elapsed_ms=%',jsonb_array_length(p->'receipts'),octet_length(p::text),round(extract(epoch FROM clock_timestamp()-started)*1000,2);
END $$;
GRANT USAGE ON SCHEMA late_fixture TO authenticated;
SET ROLE authenticated;
SELECT fixture_assert(pos_late_invoice_context(late_fixture.shop(1),md5('late-order-1')::uuid,NULL)->>'state'='ready','authenticated operator uses only definer boundary');
RESET ROLE;
SELECT fixture_assert(NOT has_table_privilege('authenticated','pos_late_invoice_requests','INSERT') AND NOT has_function_privilege('anon','pos_submit_late_invoice(uuid,uuid,uuid,uuid,jsonb,jsonb,boolean)','EXECUTE'),'raw writes and anonymous calls denied');
