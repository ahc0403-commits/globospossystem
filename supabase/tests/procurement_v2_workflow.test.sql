BEGIN;
DO $workflow$
DECLARE a jsonb:=jsonb_build_object('system','office','subject_id',test_uuid(8801),'store_id',test_uuid(101),
 'can_manage',true,'can_create',true,'can_office_approve',true,'can_senior_approve',false,'can_view_prices',true);
 senior jsonb; r jsonb; saved jsonb; qid uuid; rid uuid; lid uuid; po jsonb; data jsonb; payload jsonb; inspected jsonb; v_receipt_id uuid:=test_uuid(8890); path text; before_stock numeric; receipt_version integer; return_payload jsonb;
BEGIN
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 r:=public.procurement_command(test_uuid(101),'configure',NULL,0,'policy-v2','{"enabled":true,"high_value_amount":50,"max_price_increase_percent":20}',a);
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 payload:=jsonb_build_object('reason','Weekly ingredients','requested_delivery_date',current_date+2,
 'lines',jsonb_build_array(jsonb_build_object('product_id',test_uuid(301),'quantity',10,'unit','g')));
 r:=public.procurement_command(test_uuid(101),'create_request',NULL,0,'pr-create',payload);
 rid:=(r->>'id')::uuid;
 ASSERT r->>'status'='draft';
 ASSERT public.procurement_command(test_uuid(101),'create_request',NULL,0,'pr-create',payload)=r;
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,NULL,0,%L,%L::jsonb)',test_uuid(101),'create_request','pr-create',payload||'{"reason":"Changed"}'::jsonb),'PROCUREMENT_RETRY_MISMATCH');
 r:=public.procurement_command(test_uuid(101),'submit_request',rid,1,'pr-submit');
 data:=public.procurement_workspace(test_uuid(101),rid);
 ASSERT jsonb_array_length(data->'requests')=1;
 ASSERT NOT (data->'supplier_items'->0 ? 'unit_price');
 PERFORM public.test_expect_error(format('SELECT public.procurement_workspace(%L)',test_uuid(102)),'PROCUREMENT_SCOPE_FORBIDDEN');
 PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
 r:=public.procurement_command(test_uuid(101),'store_approve',rid,2,'store-approve');
 ASSERT r->>'status'='office_review';
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 SELECT id INTO lid FROM public.inventory_purchase_request_lines WHERE request_id=rid AND active;
 r:=public.procurement_command(test_uuid(101),'save_quote',rid,3,'save-quote',jsonb_build_object(
 'supplier_id',test_uuid(201),'valid_until',current_date+2,'delivery_date',current_date+2,
 'payment_terms','Net 7','evidence_reference','Supplier written quote 1',
 'lines',jsonb_build_array(jsonb_build_object('request_line_id',lid,'supplier_item_id',test_uuid(401),'quantity_base',10,'unit_price',100,'tax_rate',0))),a);
 SELECT id INTO qid FROM public.procurement_quotes WHERE request_id=rid;
 r:=public.procurement_command(test_uuid(101),'select_quote',rid,4,'select-quote',jsonb_build_object('quote_id',qid,'reason','Approved supplier'),a);
 -- A master-list price alone is not purchasing history for a new item.
 BEGIN
   DELETE FROM public.inventory_receipt_lines WHERE product_id=test_uuid(301);
   PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,5,%L,%L::jsonb,%L::jsonb)',
     test_uuid(101),'office_approve',rid,'new-item-one-quote','{}',a),'PROCUREMENT_COMPARATIVE_QUOTES_REQUIRED');
   RAISE EXCEPTION USING ERRCODE='Z0001',MESSAGE='Restore historical receipt fixture';
 EXCEPTION WHEN SQLSTATE 'Z0001' THEN NULL;
 END;
 r:=public.procurement_command(test_uuid(101),'office_approve',rid,5,'office-approve','{}',a);
 ASSERT r->>'status'='senior_review';
 senior:=a||jsonb_build_object('can_senior_approve',true);
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,6,%L,%L::jsonb,%L::jsonb)',
 test_uuid(101),'senior_approve',rid,'self-senior','{}',senior),'PROCUREMENT_DISTINCT_APPROVER_REQUIRED');
 senior:=senior||jsonb_build_object('subject_id',test_uuid(8802));
 r:=public.procurement_command(test_uuid(101),'senior_approve',rid,6,'senior-approve','{}',senior);
 ASSERT r->>'status'='approved';
 payload:=jsonb_build_object('quote_id',qid,'delivery_address','Store A address','contact_name','Store A receiver');
 r:=public.procurement_command(test_uuid(101),'issue_po',rid,7,'po-issue',payload,a);
 ASSERT r->>'status'='allocated';
 po:=r->'purchase_order';
 ASSERT po->>'procurement_status'='issued';
 ASSERT (po->>'total_amount')::numeric=100;
 saved:=r;
 ASSERT public.procurement_command(test_uuid(101),'issue_po',rid,7,'po-issue',payload,a)=saved;
 r:=public.procurement_command(test_uuid(101),'send_po',(po->>'id')::uuid,(po->>'row_version')::int,'po-send','{"evidence_reference":"Supplier message sent"}',a);
 ASSERT r->>'procurement_status'='sent';
 r:=public.procurement_command(test_uuid(101),'confirm_po',(po->>'id')::uuid,(r->>'row_version')::int,'po-confirm',
 jsonb_build_object('evidence_reference','Supplier accepted unchanged terms','terms_hash',po->>'approval_snapshot_hash'),a);
 ASSERT r->>'procurement_status'='confirmed';
 data:=public.procurement_workspace(test_uuid(101),rid,a);
 ASSERT jsonb_array_length(data->'orders')=1;
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(3)::text,true);
 PERFORM public.test_expect_error(format('UPDATE public.inventory_purchase_orders SET status=%L WHERE id=%L','submitted',po->>'id'),'PROCUREMENT_V2_COMMAND_REQUIRED');
 RAISE NOTICE 'PASS: PR creation/replay/scope/privacy, review, quote, distinct high-value approval, PO issue/send/confirm and legacy guard';
 -- P4 verifies the same issued PO through inspection, partial receipt, return and remainder cancellation.
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 SELECT id INTO lid FROM public.inventory_purchase_order_lines WHERE purchase_order_id=(po->>'id')::uuid;
 path:=test_uuid(101)||'/'||v_receipt_id||'/receipt.pdf';
 INSERT INTO storage.objects(bucket_id,name,metadata,owner_id) VALUES('inventory-receipt-statements',path,'{"mimetype":"application/pdf","size":120}',test_uuid(1)::text);
 inspected:='{"spec_ok":true,"quality_ok":true,"packaging_ok":true,"expiry_not_applicable":true,"issue_type":"shortage","photo_paths":[]}'::jsonb;
 payload:=jsonb_build_array(jsonb_build_object('purchase_order_line_id',lid,'received_quantity_base',8,'discrepancy_reason','Two missing','inspection',inspected));
 SELECT to_jsonb(o) INTO po FROM public.inventory_purchase_orders o WHERE id=(po->>'id')::uuid;
 PERFORM public.test_expect_error(format('SELECT public.submit_inventory_receipt_batch(%L,%L,%s,0,%L,%L::jsonb,%L,%L)',po->>'id',v_receipt_id,po->>'row_version','bad-inspection',jsonb_build_array(jsonb_build_object('purchase_order_line_id',lid,'received_quantity_base',8,'discrepancy_reason','Two missing','inspection',inspected||'{"quality_ok":false}'::jsonb)),'Inspector',path),'PROCUREMENT_FAILED_INSPECTION_CANNOT_ACCEPT');
 r:=public.submit_inventory_receipt_batch((po->>'id')::uuid,v_receipt_id,(po->>'row_version')::int,0,'good-inspection',payload,'Inspector',path);
 receipt_version:=(r->>'row_version')::int;
 SELECT current_stock INTO before_stock FROM public.inventory_items WHERE id=test_uuid(501);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(4)::text,true);
 po:=to_jsonb(public.verify_inventory_receipt(v_receipt_id,receipt_version,'inspect-verify'));
 ASSERT po->>'status'='partially_received';
 ASSERT (SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501))=before_stock+8;
 ASSERT (SELECT count(*) FROM public.inventory_receipt_issues WHERE purchase_order_id=(po->>'id')::uuid)=1;
 SELECT id INTO lid FROM public.inventory_receipt_lines WHERE receipt_id=v_receipt_id AND purchase_order_line_id=lid;
 return_payload:=jsonb_build_object('receipt_line_id',lid,'quantity_base',2,'reason','Return damaged stock','evidence_reference','Signed return note');
 r:=public.procurement_command(test_uuid(101),'return_goods',(po->>'id')::uuid,(po->>'row_version')::int,'return-goods',return_payload);
 ASSERT (SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501))=before_stock+6;
 ASSERT (SELECT quantity_g FROM public.inventory_transactions WHERE reference_type='inventory_supplier_return' AND reference_id=(r->'followup'->>'id')::uuid)=-2;
 ASSERT public.procurement_command(test_uuid(101),'return_goods',(po->>'id')::uuid,(po->>'row_version')::int,'return-goods',return_payload)=r;
 po:=r;
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 r:=public.procurement_command(test_uuid(101),'cancel_remaining',(po->>'id')::uuid,(po->>'row_version')::int,'cancel-remaining','{"reason":"Supplier cannot deliver remainder","evidence_reference":"Supplier cancellation note"}',a);
 ASSERT r->>'status'='received';
 ASSERT (SELECT cancelled_quantity_base FROM public.inventory_purchase_order_lines WHERE purchase_order_id=(po->>'id')::uuid)=2;
 saved:=public.procurement_order_snapshot(test_uuid(101),(po->>'id')::uuid,a);
 ASSERT (saved->'receipts'->0->'lines'->0->>'returned_quantity_base')::numeric=2;
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 data:=public.procurement_workspace(test_uuid(101));
 ASSERT NOT (data->'receipts'->0 ? 'total_amount');
 ASSERT NOT (data->'receipts'->0->'lines'->0 ? 'final_supply_amount');
 RAISE NOTICE 'PASS: QC failures rejected, partial receipt issue, atomic return/replay, cancellation and price privacy';

END $workflow$;
ROLLBACK;
BEGIN;
DO $$ DECLARE d jsonb;BEGIN
 PERFORM set_config('request.jwt.claim.role','authenticated',true);PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 INSERT INTO public.inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,created_at) VALUES
 (test_uuid(101),test_uuid(501),'deduct',-28,'order',now()-interval '2 days'),
 (test_uuid(101),test_uuid(501),'deduct',-280,'inventory_supplier_return',now()-interval '2 days'),
 (test_uuid(101),test_uuid(501),'waste',-14,'waste',now()-interval '2 days');
 SELECT e INTO d FROM jsonb_array_elements(public.procurement_demand_evidence(test_uuid(101))) e WHERE e->>'product_id'=test_uuid(301)::text;
 ASSERT (d->>'actual_daily_usage_base')::numeric=1;
 ASSERT (d->>'waste_daily_base')::numeric=0.5;
 ASSERT (d->>'mapping_count')::int>1,'Shared stock mapping must be visible to replenishment guard';
 RAISE NOTICE 'PASS: actual usage excludes supplier returns, waste is separate, ambiguous product mappings flagged';
END$$;
ROLLBACK;
BEGIN;
DO $$DECLARE po public.inventory_purchase_orders%rowtype;a jsonb;payload jsonb;r jsonb;l uuid;before_qty numeric;BEGIN
 a:=jsonb_build_object('system','office','subject_id',test_uuid(8801),'store_id',test_uuid(101),'can_manage',true,'can_create',true,'can_office_approve',true,'can_senior_approve',true,'can_view_prices',true);
 PERFORM set_config('request.jwt.claim.role','authenticated',true);PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 po:=public.create_manual_inventory_purchase_order(test_uuid(101),test_uuid(201),jsonb_build_array(jsonb_build_object('supplier_item_id',test_uuid(401),'ordered_quantity_unit',1)),current_date,NULL);
 po:=public.submit_inventory_purchase_order(po.id,po.row_version);PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);po:=public.store_decide_inventory_purchase_order(po.id,po.row_version,true,NULL);PERFORM set_config('request.jwt.claim.sub',test_uuid(3)::text,true);po:=public.brand_decide_inventory_purchase_order(po.id,po.row_version,true,NULL);
 PERFORM set_config('app.procurement_terms_repair','true',true);
 UPDATE public.inventory_purchase_order_lines SET tax_rate_snapshot=NULL WHERE purchase_order_id=po.id RETURNING id INTO l;
 PERFORM set_config('app.procurement_terms_repair','',true);
 payload:=jsonb_build_object('reason','Reviewed original signed PO','evidence_reference','Archived PO document', 'lines',jsonb_build_array(jsonb_build_object('id',l,'conversion',10,'tax_rate',0,'base_unit','g')));
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,%s,%L,%L::jsonb)',test_uuid(101),'repair_legacy_terms',po.id,po.row_version,'forbidden-repair',payload),'PROCUREMENT_TERMS_REVIEW_FORBIDDEN');
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 r:=public.procurement_command(test_uuid(101),'repair_legacy_terms',po.id,po.row_version,'legacy-repair',payload,a);
 ASSERT (SELECT tax_rate_snapshot FROM public.inventory_purchase_order_lines WHERE id=l)=0;
 ASSERT public.procurement_command(test_uuid(101),'repair_legacy_terms',po.id,po.row_version,'legacy-repair',payload,a)=r;
 PERFORM public.procurement_command(test_uuid(101),'configure',NULL,0,'amend-policy','{"enabled":true}',a);
 PERFORM set_config('app.procurement_write','true',true);
 UPDATE public.inventory_purchase_orders SET workflow_version=2,procurement_status='confirmed' WHERE id=po.id RETURNING * INTO po;
 PERFORM set_config('app.procurement_write','',true);
 payload:=jsonb_build_object('reason','Supplier proposed changed terms','evidence_reference','Supplier cancelled old PO','requested_delivery_date',current_date+2);
 r:=public.procurement_command(test_uuid(101),'amend_po',po.id,po.row_version,'amend-order',payload,a);
 ASSERT r->>'status'='cancelled';ASSERT r->'followup'->>'status'='draft';
 ASSERT (SELECT count(*) FROM public.inventory_purchase_request_lines WHERE request_id=(r->'followup'->>'id')::uuid)=1;
 ASSERT public.procurement_command(test_uuid(101),'amend_po',po.id,po.row_version,'amend-order',payload,a)=r;
 RAISE NOTICE 'PASS: authorized historical-term repair and cancellation/reapproval amendment preserve replay identity';
END $$;
ROLLBACK;
