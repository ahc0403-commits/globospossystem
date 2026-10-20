BEGIN;
UPDATE public.restaurants SET is_active=true WHERE id=test_uuid(101);
INSERT INTO auth.users(id) VALUES(test_uuid(99501));
INSERT INTO public.users(id,auth_id,role,restaurant_id,is_active,fixed_account_code,account_type)
 VALUES(test_uuid(99502),test_uuid(99501),'inventory_orderer',test_uuid(101),true,'unified_pr1','inventory_orderer');
INSERT INTO public.user_store_access(user_id,store_id,is_active,source_type)
 VALUES(test_uuid(99502),test_uuid(101),true,'direct');
INSERT INTO public.store_fixed_account_requirements(
 store_id,account_code,account_type,role,display_name,scope,provisioned_user_id,is_active)
 VALUES(test_uuid(101),'unified_pr1','inventory_orderer','inventory_orderer',
 'Unified fixture','store',test_uuid(99502),true);

DO $test$
DECLARE po public.inventory_purchase_orders%rowtype;line_id uuid;before_stock numeric;
 receipt uuid:=test_uuid(99503);second uuid:=test_uuid(99504);path text;result jsonb;prior jsonb;
 payload jsonb;order_version integer;started timestamptz:=clock_timestamp();
 inspection jsonb:='{"spec_ok":true,"quality_ok":true,"packaging_ok":true,"expiry_not_applicable":true,"issue_type":"none","photo_paths":[]}';
BEGIN
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(99501)::text,true);
 ASSERT (SELECT count(*) FROM public.procurement_role_roster WHERE
   restaurant_id=test_uuid(101) AND subject_id=test_uuid(99501)
   AND system='pos' AND stage IN('requester','receiver','verifier'))=3;
 ASSERT public.can_create_inventory_purchase_order(test_uuid(101));
 ASSERT public.can_receive_and_confirm_inventory_receipt(test_uuid(101));
 ASSERT public.can_verify_inventory_receipt(test_uuid(101));
 ASSERT NOT public.can_receive_and_confirm_inventory_receipt(test_uuid(102));
 ASSERT NOT (public.get_inventory_order_catalog(test_uuid(101))->'actor'->>'receiving_only')::boolean;
 ASSERT NOT (public.procurement_actor(test_uuid(101))->>'can_view_prices')::boolean;
 UPDATE public.procurement_role_roster SET valid_from=now()-interval '1 day',valid_until=now()-interval '1 second'
   WHERE subject_id=test_uuid(99501) AND stage='verifier';
 ASSERT NOT public.can_receive_and_confirm_inventory_receipt(test_uuid(101));
 UPDATE public.procurement_role_roster SET valid_until='infinity'
   WHERE subject_id=test_uuid(99501) AND stage='verifier';
 UPDATE public.users SET is_active=false WHERE id=test_uuid(99502);
 ASSERT NOT public.can_receive_and_confirm_inventory_receipt(test_uuid(101));
 UPDATE public.users SET is_active=true WHERE id=test_uuid(99502);

 UPDATE public.procurement_store_policies SET enabled=false,three_stage_required=false
   WHERE restaurant_id=test_uuid(101);
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
 PERFORM set_config('request.jwt.claim.sub',test_uuid(99501)::text,true);
 path:=test_uuid(101)||'/'||receipt||'/receipt.pdf';
 INSERT INTO storage.objects(bucket_id,name,metadata,owner_id)
 VALUES('inventory-receipt-statements',path,'{"mimetype":"application/pdf","size":120}',test_uuid(99501)::text);
 result:=public.submit_inventory_receipt_batch(po.id,receipt,po.row_version,0,'unified-legacy',
   jsonb_build_array(jsonb_build_object('purchase_order_line_id',line_id,'received_quantity_base',6,
     'discrepancy_reason','Split delivery','inspection',inspection)),'Receiver',path);
 ASSERT result->>'status'='confirmed','Same PR account confirms legacy receiving';
 ASSERT (SELECT received_by=verified_by AND received_by=test_uuid(99501) FROM public.inventory_receipts WHERE id=receipt);
 ASSERT (SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501))=before_stock+6;

 -- Exercise the current policy-3 atomic endpoint on the outstanding delivery.
 UPDATE public.inventory_purchase_orders SET commercial_terms=commercial_terms||
   '{"approval_policy_version":3}' WHERE id=po.id RETURNING * INTO po;
 order_version:=po.row_version;
 path:=test_uuid(101)||'/'||second||'/receipt.pdf';
 INSERT INTO storage.objects(bucket_id,name,metadata,owner_id)
 VALUES('inventory-receipt-statements',path,'{"mimetype":"application/pdf","size":120}',test_uuid(99501)::text);
 payload:=jsonb_build_object('p_purchase_order_id',po.id,'p_receipt_id',second,
   'p_expected_order_version',order_version,'p_expected_receipt_version',0,
   'p_idempotency_key','unified-policy3','p_inspector_name','Receiver','p_statement_storage_path',path,
   'p_lines',jsonb_build_array(jsonb_build_object('purchase_order_line_id',line_id,
     'received_quantity_base',4,'inspection',inspection)));
 result:=public.finalize_procurement_receipt(payload);
 ASSERT result->>'status'='confirmed';
 ASSERT (SELECT status FROM public.inventory_purchase_orders WHERE id=po.id)='received';
 ASSERT (SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501))=before_stock+10;
 prior:=public.finalize_procurement_receipt(payload);
 ASSERT prior=result,'Same operation key returns the original result';
 ASSERT (SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501))=before_stock+10;
 ASSERT (SELECT count(*) FROM public.inventory_transactions WHERE reference_id=second)=1;
 RAISE NOTICE 'UNIFIED_REQUESTER_RECEIVING=PASS onboarding=3 scope_guard=true legacy=6 policy3=4 stock_delta=10 replay_delta=0 rpc_calls=1 db_ms=%',
   extract(epoch FROM clock_timestamp()-started)*1000;
END $test$;
ROLLBACK;
