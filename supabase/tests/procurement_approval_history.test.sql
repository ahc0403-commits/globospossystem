BEGIN;
DO $test$
DECLARE r jsonb;page jsonb;inbox jsonb;rid uuid;lid uuid;qid uuid;approval jsonb;
 buyer jsonb:=jsonb_build_object('system','office','subject_id',test_uuid(15001),'role','staff','store_id',test_uuid(101),'office_store_id',test_uuid(101),'can_read',true,'can_create',true,'can_office_approve',true,'can_view_prices',true);
BEGIN
 UPDATE public.procurement_store_policies SET enabled=true,two_stage_required=true,new_requests_enabled=true WHERE restaurant_id=test_uuid(101);
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 r:=public.procurement_command(test_uuid(101),'create_request',NULL,0,'history-create',jsonb_build_object('reason','Approval handoff regression','requested_delivery_date',current_date+2,'lines',jsonb_build_array(jsonb_build_object('product_id',test_uuid(301),'quantity',10,'unit','g'))));rid:=(r->>'id')::uuid;
 SELECT id INTO lid FROM public.inventory_purchase_request_lines WHERE request_id=rid AND active;
 r:=public.procurement_command(test_uuid(101),'submit_request',rid,1,'history-submit');
 PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
 page:=public.procurement_workspace_page(test_uuid(101),'{"request_scope":"history","request_view":true}');
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(page->'requests') x WHERE x->>'id'=rid::text),'Unprocessed PR is not approval history';
 approval:=public.procurement_command(test_uuid(101),'store_approve',rid,2,'history-store');
 ASSERT approval->>'status'='office_review';
 ASSERT public.procurement_command(test_uuid(101),'store_approve',rid,2,'history-store')=approval,'Retry preserves approval';
 page:=public.procurement_workspace_page(test_uuid(101),'{"request_scope":"mine","request_group":"pending","request_view":true}');
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(page->'requests') x WHERE x->>'id'=rid::text),'Completed store step leaves current inbox';
 page:=public.procurement_workspace_page(test_uuid(101),jsonb_build_object('request_scope','history','request_view',true,'request_id',rid));
 ASSERT (SELECT count(*) FROM jsonb_array_elements(page->'requests') x WHERE x->>'id'=rid::text)=1,'Store approval remains in history during Office review';
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(page->'events') e WHERE e->>'action'='store_approve'),'Approval evidence remains readable';
 ASSERT NOT(page->'request_detail'->'allowed_actions' ? 'store_approve'),'History never grants repeat approval';
 page:=public.procurement_workspace_page(test_uuid(101),jsonb_build_object('approval_view',true,'request_group','approved','request_sort','created','request_view',true,'request_summary_only',true,'search',approval->>'request_no'));
 ASSERT jsonb_array_length(page->'requests')=1 AND page->'requests'->0->>'status'='office_review','Approved tab includes store-approved PR before final Office approval';
 ASSERT page->'request_counts'->>'approved'='1' AND page->'request_counts'->>'pending'='0','Tab counts use the same current stage and search scope';
 ASSERT jsonb_array_length(page->'products')=0 AND jsonb_array_length(page->'supplier_items')=0,'Inbox summary omits unused catalog';
 ASSERT NULLIF(page->'requests'->0->>'requester_name','') IS NOT NULL,'Requester account label comes from the recorded actor';

 PERFORM public.test_expect_error(format('SELECT public.procurement_workspace_page(%L,%L::jsonb)',test_uuid(102),'{"request_scope":"history"}'),'PROCUREMENT_SCOPE_FORBIDDEN');
 PERFORM public.test_expect_error(format('SELECT public.procurement_workspace_page(%L,%L::jsonb)',test_uuid(101),'{"request_scope":"unknown"}'),'PROCUREMENT_FILTER_INVALID');
 PERFORM set_config('request.jwt.claim.sub',test_uuid(3)::text,true);
 page:=public.procurement_workspace_page(test_uuid(101),'{"request_scope":"history","request_view":true}');
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(page->'requests') x WHERE x->>'id'=rid::text),'Another account cannot claim the approver history';
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 inbox:=public.procurement_approval_inbox_batch((SELECT jsonb_build_array(jsonb_build_object('store_id',id,'brand_id',brand_id,'tax_entity_id',tax_entity_id,'actor',buyer)) FROM public.restaurants WHERE id=test_uuid(101)),'{}');
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(inbox->'requests') x WHERE x->>'id'=rid::text AND x->>'status'='office_review' AND x->'allowed_actions' ? 'office_approve'),'Same PR is actionable in Office buyer inbox';
 r:=public.procurement_command(test_uuid(101),'save_quote',rid,3,'history-quote',jsonb_build_object('supplier_id',test_uuid(201),'valid_until',current_date+2,'delivery_date',current_date+2,'payment_terms','Net 7','evidence_reference','Written quote','lines',jsonb_build_array(jsonb_build_object('request_line_id',lid,'supplier_item_id',test_uuid(401),'quantity_base',10,'unit_price',100,'tax_rate',0))),buyer);
 SELECT id INTO qid FROM public.procurement_quotes WHERE request_id=rid;
 r:=public.procurement_command(test_uuid(101),'select_quote',rid,4,'history-select',jsonb_build_object('quote_id',qid,'reason','Selected'),buyer);
 r:=public.procurement_command(test_uuid(101),'office_approve',rid,5,'history-buyer','{}',buyer);
 ASSERT r->>'status'='approved';
 page:=public.procurement_workspace_page(test_uuid(101),'{"request_scope":"history","request_view":true}',buyer);
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(page->'requests') x WHERE x->>'id'=rid::text),'Buyer history survives final approval';
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
 page:=public.procurement_workspace_page(test_uuid(101),'{"request_scope":"history","request_view":true}');
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(page->'requests') x WHERE x->>'id'=rid::text AND x->>'status'='approved'),'Store history survives later buyer approval';

 -- Same timestamps use a stable descending ID cursor; returned/cancelled are distinct.
 PERFORM set_config('app.procurement_write','true',true);
 INSERT INTO public.inventory_purchase_requests(id,restaurant_id,source,requested_delivery_date,reason,created_actor,status,approval_policy_version,created_at,submitted_at)
 SELECT test_uuid(15010+n),test_uuid(101),'pos',current_date,'Layout cursor fixture',jsonb_build_object('system','pos','subject_id',test_uuid(1),'display_name','Recorded requester','role','inventory_orderer'),'submitted',3,
   CASE WHEN n=1 THEN now()-interval '1 day' ELSE now() END,now() FROM generate_series(1,3) n;
 page:=public.procurement_workspace_page(test_uuid(101),'{"approval_view":true,"request_group":"pending","request_sort":"created","request_view":true,"request_summary_only":true,"search":"Layout cursor fixture","limit":2}');
 ASSERT page->'requests'->0->>'id'=test_uuid(15013)::text AND page->'requests'->1->>'id'=test_uuid(15012)::text,'Latest request date then ID descending';
 ASSERT page->'request_counts'->>'pending'='3' AND (page->>'request_has_more')::boolean;
 inbox:=public.procurement_workspace_page(test_uuid(101),jsonb_build_object('approval_view',true,'request_group','pending','request_sort','created','request_view',true,'request_summary_only',true,'search','Layout cursor fixture','limit',2,'request_before',page->'requests'->1->>'created_at','request_before_id',page->'requests'->1->>'id'));
 ASSERT jsonb_array_length(inbox->'requests')=1 AND inbox->'requests'->0->>'id'=test_uuid(15011)::text,'Latest cursor neither repeats nor omits equal timestamps';
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 r:=public.procurement_command(test_uuid(101),'create_request',NULL,0,'layout-return-create',jsonb_build_object('reason','Returned layout fixture','requested_delivery_date',current_date+2,'lines',jsonb_build_array(jsonb_build_object('product_id',test_uuid(301),'quantity',10,'unit','g'))));rid:=(r->>'id')::uuid;
 r:=public.procurement_command(test_uuid(101),'submit_request',rid,1,'layout-return-submit');
 PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
 r:=public.procurement_command(test_uuid(101),'return_request',rid,2,'layout-return','{"reason":"Adjust quantity"}');
 page:=public.procurement_workspace_page(test_uuid(101),'{"approval_view":true,"request_group":"returned","request_view":true,"request_summary_only":true,"search":"Returned layout fixture"}');
 ASSERT jsonb_array_length(page->'requests')=1 AND page->'request_counts'->>'returned'='1' AND page->'request_counts'->>'pending'='0','Actual return appears only in returned tab';
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 r:=public.procurement_command(test_uuid(101),'submit_request',rid,3,'layout-return-resubmit');
 PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
 page:=public.procurement_workspace_page(test_uuid(101),'{"approval_view":true,"request_group":"pending","request_view":true,"request_summary_only":true,"search":"Returned layout fixture"}');
 ASSERT jsonb_array_length(page->'requests')=1 AND page->'request_counts'->>'returned'='0' AND page->'request_counts'->>'pending'='1','Resubmission moves current revision to pending without erasing old return';
 RAISE NOTICE 'PASS: real store approval -> history -> actionable Office inbox -> final buyer approval; retry and identity/store isolation';
END $test$;
ROLLBACK;
