DO $upgrade$
DECLARE state record;buyer jsonb:=jsonb_build_object('system','office','subject_id',test_uuid(9701),'store_id',test_uuid(101),'can_office_approve',true,'can_view_prices',true);r jsonb;qid uuid;version integer;
BEGIN
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 FOR state IN SELECT * FROM public.test_procurement_upgrade_state LOOP
 ASSERT public.procurement_request_hash(state.request_id)=state.approval_hash,'An in-flight approval must retain its exact pre-upgrade hash';
 ASSERT (SELECT approval_policy_version FROM public.inventory_purchase_requests WHERE id=state.request_id)=1;
 IF state.purchase_order_id IS NOT NULL THEN
 ASSERT public.procurement_order_snapshot(test_uuid(101),state.purchase_order_id,buyer)=state.snapshot,'An unchanged legacy accounting snapshot must remain byte-compatible';
 ELSE
 SELECT row_version INTO version FROM public.inventory_purchase_requests WHERE id=state.request_id;
 SELECT id INTO qid FROM public.procurement_quotes WHERE request_id=state.request_id AND selected;
 r:=public.procurement_command(test_uuid(101),'issue_po',state.request_id,version,'upgrade-issue-1',jsonb_build_object('quote_id',qid,'delivery_address','Store address','contact_name','Receiver'),buyer);
 ASSERT r->>'status'='allocated';
 END IF;
 END LOOP;
 RAISE NOTICE 'PASS: actual pre-upgrade approval/accounting hashes preserved; in-flight approved PR can still issue a PO';
END $upgrade$;
DROP TABLE public.test_procurement_upgrade_state;
