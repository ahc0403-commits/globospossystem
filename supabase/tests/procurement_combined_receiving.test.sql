BEGIN;
UPDATE public.restaurants SET is_active=true WHERE id=test_uuid(101);
INSERT INTO public.user_store_access(user_id,store_id,is_active) VALUES(test_uuid(1),test_uuid(101),true);
DO $test$
DECLARE buyer jsonb:=jsonb_build_object('system','office','subject_id',test_uuid(9901),
 'store_id',test_uuid(101),'can_manage',true);
 payload jsonb;result jsonb;prior jsonb;detail jsonb;po public.inventory_purchase_orders%rowtype;
 receipt uuid:=test_uuid(98601);second_receipt uuid:=test_uuid(98602);path text;line_id uuid;
 allowed boolean;before_stock numeric;before_version integer;before_attempts integer;
 inspection jsonb:='{"spec_ok":true,"quality_ok":true,"packaging_ok":true,"expiry_not_applicable":true,"issue_type":"none","photo_paths":[]}';
BEGIN
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 SELECT public.can_receive_and_confirm_inventory_receipt(test_uuid(101)) INTO allowed; ASSERT NOT allowed;
 ASSERT NOT public.can_verify_inventory_receipt(test_uuid(101));
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 payload:=jsonb_build_object('account_kind','shared_role','system','pos','subject_id',test_uuid(1),
  'stage','verifier','valid_from',now()-interval '1 day','valid_until',now()+interval '365 days',
  'reason','Owner requested one receiving and inspection account');
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,NULL,0,%L,%L::jsonb,%L::jsonb)',
  test_uuid(101),'assign_principal','combined-no-receiver',payload,buyer),'PROCUREMENT_PRINCIPAL_STAGE_FORBIDDEN');
 PERFORM public.procurement_command(test_uuid(101),'assign_principal',NULL,0,'combined-receiver',
  payload||'{"stage":"receiver"}'::jsonb,buyer);
 PERFORM public.procurement_command(test_uuid(101),'assign_principal',NULL,0,'combined-verifier',payload,buyer);
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 SELECT public.can_receive_and_confirm_inventory_receipt(test_uuid(101)) INTO allowed; ASSERT allowed, 'Assigned receiver can confirm';
 SELECT public.can_verify_inventory_receipt(test_uuid(101)) INTO allowed; ASSERT allowed, 'Assigned receiver can verify';
 ASSERT NOT public.can_receive_and_confirm_inventory_receipt(test_uuid(102));
 UPDATE public.procurement_role_roster SET valid_until=now()-interval '1 second'
  WHERE subject_id=test_uuid(1) AND stage='verifier';
 SELECT public.can_receive_and_confirm_inventory_receipt(test_uuid(101)) INTO allowed; ASSERT NOT allowed;
 UPDATE public.procurement_role_roster SET valid_until=now()+interval '365 days'
  WHERE subject_id=test_uuid(1) AND stage='verifier';
 UPDATE public.users SET is_active=false WHERE auth_id=test_uuid(1);
 SELECT public.can_receive_and_confirm_inventory_receipt(test_uuid(101)) INTO allowed; ASSERT NOT allowed;
 UPDATE public.users SET is_active=true WHERE auth_id=test_uuid(1);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(5)::text,true);
 ASSERT NOT public.can_verify_inventory_receipt(test_uuid(101));
 PERFORM set_config('request.jwt.claim.sub',test_uuid(4)::text,true);
 ASSERT public.can_verify_inventory_receipt(test_uuid(101)), 'Existing accounting access retained';

 -- Prepare an approved PO through the native legacy path, then exercise the
 -- stricter v2 inspection and supplier-confirmation contracts on that fixture.
 UPDATE public.procurement_store_policies SET enabled=false WHERE restaurant_id=test_uuid(101);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 po:=public.create_manual_inventory_purchase_order(test_uuid(101),test_uuid(201),
  jsonb_build_array(jsonb_build_object('supplier_item_id',test_uuid(401),'ordered_quantity_unit',1)),current_date,NULL);
 po:=public.submit_inventory_purchase_order(po.id,po.row_version);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
 po:=public.store_decide_inventory_purchase_order(po.id,po.row_version,true,NULL);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(3)::text,true);
 po:=public.brand_decide_inventory_purchase_order(po.id,po.row_version,true,NULL);
 PERFORM set_config('app.procurement_write','true',true);
 UPDATE public.inventory_purchase_orders SET workflow_version=2,procurement_status='confirmed'
  WHERE id=po.id RETURNING * INTO po;
 SELECT id INTO line_id FROM public.inventory_purchase_order_lines WHERE purchase_order_id=po.id;
 SELECT current_stock INTO before_stock FROM public.inventory_items WHERE id=test_uuid(501);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 detail:=public.get_inventory_workflow_detail(po.id);
 ASSERT (detail->>'can_receive_and_confirm')::boolean;
 path:=test_uuid(101)||'/'||receipt||'/receipt.pdf';
 INSERT INTO storage.objects(bucket_id,name,metadata,owner_id)
  VALUES('inventory-receipt-statements',path,'{"mimetype":"application/pdf","size":120}',test_uuid(1)::text);
 payload:=jsonb_build_array(jsonb_build_object('purchase_order_line_id',line_id,
  'received_quantity_base',6,'actual_unit_price',100,'discrepancy_reason','Split delivery','inspection',inspection));
 before_version:=po.row_version;
 result:=public.submit_inventory_receipt_batch(po.id,receipt,before_version,0,'combined-first',payload,'Receiver',path);
 ASSERT result->>'status'='confirmed' AND (result->>'combined_receiving')::boolean;
 ASSERT (SELECT received_by=verified_by FROM public.inventory_receipts WHERE id=receipt);
 ASSERT (SELECT status FROM public.inventory_purchase_orders WHERE id=po.id)='partially_received';
 ASSERT (SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501))=before_stock+6;
 prior:=public.submit_inventory_receipt_batch(po.id,receipt,before_version,0,'combined-first',payload,'Receiver',path);
 ASSERT prior=result;
 ASSERT (SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501))=before_stock+6;
 PERFORM public.test_expect_error(format('SELECT public.submit_inventory_receipt_batch(%L,%L,%s,0,%L,%L::jsonb,%L,%L)',
  po.id,receipt,before_version,'combined-first',payload,'Changed inspector',path),'INVENTORY_RECEIPT_RETRY_MISMATCH');
 SELECT * INTO po FROM public.inventory_purchase_orders WHERE id=po.id;
 path:=test_uuid(101)||'/'||second_receipt||'/receipt.pdf';
 INSERT INTO storage.objects(bucket_id,name,metadata,owner_id)
  VALUES('inventory-receipt-statements',path,'{"mimetype":"application/pdf","size":120}',test_uuid(1)::text);
 payload:=jsonb_build_array(jsonb_build_object('purchase_order_line_id',line_id,
  'received_quantity_base',4,'actual_unit_price',100,'inspection',inspection));
 -- A confirmation failure must roll back the submitted receipt and retry row.
 UPDATE public.inventory_products SET inventory_item_id=NULL WHERE id=test_uuid(301);
 before_attempts:=(SELECT count(*) FROM public.inventory_receipt_submission_attempts);
 PERFORM public.test_expect_error(format('SELECT public.submit_inventory_receipt_batch(%L,%L,%s,0,%L,%L::jsonb,%L,%L)',
  po.id,second_receipt,po.row_version,'combined-second',payload,'Receiver',path),'INVENTORY_RECEIPT_STOCK_MAPPING_REQUIRED');
 ASSERT NOT EXISTS(SELECT 1 FROM public.inventory_receipts WHERE id=second_receipt);
 ASSERT (SELECT count(*) FROM public.inventory_receipt_submission_attempts)=before_attempts;
 UPDATE public.inventory_products SET inventory_item_id=test_uuid(501) WHERE id=test_uuid(301);
 result:=public.submit_inventory_receipt_batch(po.id,second_receipt,po.row_version,0,'combined-second',payload,'Receiver',path);
 ASSERT result->>'status'='confirmed';
 ASSERT (SELECT status FROM public.inventory_purchase_orders WHERE id=po.id)='received';
 ASSERT (SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501))=before_stock+10;
 ASSERT NOT EXISTS(SELECT 1 FROM public.inventory_receipt_issues WHERE receipt_line_id IN(
  SELECT id FROM public.inventory_receipt_lines WHERE receipt_id=second_receipt));
 RAISE NOTICE 'PASS: shared receiving assignment, scope, expiry, atomic 6+4 delivery, rollback and retry';
END $test$;
ROLLBACK;
