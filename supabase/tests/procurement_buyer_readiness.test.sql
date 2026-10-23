BEGIN;
DO $test$
DECLARE rid uuid:=gen_random_uuid();lid uuid:=gen_random_uuid();qid uuid:=gen_random_uuid();
 alt uuid:=gen_random_uuid();alt_quote uuid:=gen_random_uuid();alt_item uuid:=gen_random_uuid();foreign_request uuid:=gen_random_uuid();foreign_quote uuid:=gen_random_uuid();
 buyer jsonb:=jsonb_build_object('system','office','subject_id',test_uuid(23001),'store_id',test_uuid(101),
   'office_store_id',test_uuid(23002),'store_name','Mapped Office store','role','staff',
   'can_read',true,'can_create',true,'can_office_approve',true,'can_view_prices',true);
 scopes jsonb;page jsonb;row jsonb;detail jsonb;blockers jsonb;result jsonb;before_count bigint;
BEGIN
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 PERFORM set_config('app.procurement_write','true',true);
 UPDATE public.procurement_store_policies SET enabled=true,max_price_increase_percent=20 WHERE restaurant_id=test_uuid(101);
 INSERT INTO public.inventory_purchase_requests(id,restaurant_id,source,status,requested_delivery_date,reason,
   created_actor,store_approved_actor,store_approved_at,submitted_at,approval_policy_version)
 VALUES(rid,test_uuid(101),'pos','office_review',current_date+1,'Buyer readiness fixture',
   jsonb_build_object('system','pos','subject_id',test_uuid(1)),
   jsonb_build_object('system','pos','subject_id',test_uuid(2)),now(),now()-interval '200 days',3);
 INSERT INTO public.inventory_purchase_request_lines(id,request_id,product_id,requested_quantity,requested_unit,quantity_base,conversion_snapshot)
 VALUES(lid,rid,test_uuid(301),10,'g',10,1);
 SELECT jsonb_build_array(jsonb_build_object('store_id',r.id,'brand_id',r.brand_id,'tax_entity_id',r.tax_entity_id,'actor',buyer))
 INTO scopes FROM public.restaurants r WHERE r.id=test_uuid(101);

 page:=public.procurement_approval_inbox_batch(scopes);
 SELECT r INTO row FROM jsonb_array_elements(page->'requests') r WHERE r->>'id'=rid::text;
 ASSERT page->>'approval_readiness_version'='1';
 ASSERT row->>'office_store_id'=test_uuid(23002)::text,'Native Office ID must survive POS mapping';
 ASSERT NOT(row->>'approval_ready')::boolean AND row->'approval_blockers' ? 'PROCUREMENT_QUOTE_REQUIRED';
 ASSERT row->>'next_action'='save_quote';
 ASSERT (page->'approval_counts'->>'pending')::integer=(page->'approval_counts'->>'actionable')::integer+(page->'approval_counts'->>'blocked')::integer;
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(page->'requests') r WHERE r->>'status'='submitted'),'Buyer counts exclude store-manager stages';
 detail:=public.procurement_workspace_page(test_uuid(101),jsonb_build_object('request_id',rid),buyer);
 ASSERT detail->'request_detail'->'approval_blockers'=row->'approval_blockers','Inbox and selected detail share checks';
 ASSERT NOT(public.procurement_workspace_page(test_uuid(101),'{"catalog_only":true}',buyer) ? 'approval_counts'),'Catalog paging skips unrelated readiness aggregation';
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,1,%L,%L::jsonb,%L::jsonb)',
   test_uuid(101),'office_approve',rid,'readiness-no-quote','{}',buyer),'PROCUREMENT_QUOTE_REQUIRED');

 INSERT INTO public.procurement_quotes(id,request_id,supplier_id,valid_until,delivery_date,payment_terms,evidence_reference)
 VALUES(qid,rid,test_uuid(201),current_date+2,current_date+1,'Net 7','Fixture quote');
 INSERT INTO public.procurement_quote_lines(quote_id,request_line_id,supplier_item_id,quantity_base,order_unit,conversion_snapshot,unit_price,tax_rate,reference_unit_price)
 VALUES(qid,lid,test_uuid(401),10,'g',1,100,0,100);
 SELECT approval_blockers INTO blockers FROM public.procurement_buyer_readiness(ARRAY[rid]);
 ASSERT blockers ? 'PROCUREMENT_QUOTE_SELECTION_REQUIRED','An unselected quote does not make approval ready';
 UPDATE public.procurement_quotes SET selected=true,valid_until=current_date-1 WHERE id=qid;
 SELECT approval_blockers INTO blockers FROM public.procurement_buyer_readiness(ARRAY[rid]);
 ASSERT blockers ? 'PROCUREMENT_QUOTE_EXPIRED';
 UPDATE public.procurement_quotes SET valid_until=current_date+2 WHERE id=qid;
 UPDATE public.procurement_quote_lines SET quantity_base=9 WHERE quote_id=qid;
 SELECT approval_blockers INTO blockers FROM public.procurement_buyer_readiness(ARRAY[rid]);
 ASSERT blockers ? 'PROCUREMENT_QUOTE_COVERAGE_REQUIRED';
 UPDATE public.procurement_quote_lines SET quantity_base=10,reference_unit_price=0 WHERE quote_id=qid;
 SELECT approval_blockers INTO blockers FROM public.procurement_buyer_readiness(ARRAY[rid]);
 ASSERT blockers ? 'PROCUREMENT_COMPARATIVE_QUOTES_REQUIRED';
 INSERT INTO public.inventory_suppliers(id,supplier_name) VALUES(alt,'Comparison fixture supplier');
 INSERT INTO public.inventory_supplier_items(id,supplier_id,product_id,order_unit,order_unit_quantity_base,min_order_quantity,unit_price)
 VALUES(alt_item,alt,test_uuid(301),'g',1,1,105);
 INSERT INTO public.procurement_quotes(id,request_id,supplier_id,valid_until,delivery_date,payment_terms,evidence_reference)
 VALUES(alt_quote,rid,alt,current_date+2,current_date+1,'Net 7','Comparison fixture');
 INSERT INTO public.procurement_quote_lines(quote_id,request_line_id,supplier_item_id,quantity_base,order_unit,conversion_snapshot,unit_price,tax_rate,reference_unit_price)
 VALUES(alt_quote,lid,alt_item,10,'g',1,105,0,100);
 SELECT approval_blockers INTO blockers FROM public.procurement_buyer_readiness(ARRAY[rid]);
 ASSERT blockers='[]','Complete valid quotes and comparison are ready';
 -- Corrupt cross-PR references must not change another request's grouped coverage.
 INSERT INTO public.inventory_purchase_requests(id,restaurant_id,source,status,requested_delivery_date,reason,created_actor,store_approved_actor,approval_policy_version)
 VALUES(foreign_request,test_uuid(101),'pos','office_review',current_date+1,'Cross-reference fixture','{}','{}',3);
 INSERT INTO public.procurement_quotes(id,request_id,supplier_id,valid_until,delivery_date,payment_terms,evidence_reference,selected)
 VALUES(foreign_quote,foreign_request,test_uuid(201),current_date+2,current_date+1,'Net 7','Cross-reference fixture',true);
 INSERT INTO public.procurement_quote_lines(quote_id,request_line_id,supplier_item_id,quantity_base,order_unit,conversion_snapshot,unit_price,tax_rate,reference_unit_price)
 VALUES(foreign_quote,lid,test_uuid(401),10,'g',1,100,0,100);
 SELECT approval_blockers INTO blockers FROM public.procurement_buyer_readiness(ARRAY[rid,foreign_request]) WHERE request_id=rid;
 ASSERT blockers='[]','Readiness aggregation preserves the request/line boundary';
 DELETE FROM public.procurement_quote_lines WHERE quote_id=foreign_quote;
 DELETE FROM public.procurement_quotes WHERE id=foreign_quote;
 DELETE FROM public.inventory_purchase_requests WHERE id=foreign_request;

 page:=public.procurement_approval_inbox_batch(scopes);
 SELECT r INTO row FROM jsonb_array_elements(page->'requests') r WHERE r->>'id'=rid::text;
 ASSERT (row->>'approval_ready')::boolean;
 detail:=public.procurement_workspace_page(test_uuid(101),jsonb_build_object('request_id',rid),buyer);
 ASSERT (detail->'request_detail'->>'approval_ready')::boolean;

 UPDATE public.procurement_store_policies SET enabled=false WHERE restaurant_id=test_uuid(101);
 page:=public.procurement_approval_inbox_batch(scopes);
 SELECT r INTO row FROM jsonb_array_elements(page->'requests') r WHERE r->>'id'=rid::text;
 ASSERT row->'approval_blockers' ? 'PROCUREMENT_NOT_ENABLED' AND NOT(row->>'approval_ready')::boolean;
 UPDATE public.procurement_store_policies SET enabled=true WHERE restaurant_id=test_uuid(101);
 page:=public.procurement_approval_inbox_batch(jsonb_set(scopes,'{0,actor,subject_id}',to_jsonb(test_uuid(1)::text)));
 SELECT r INTO row FROM jsonb_array_elements(page->'requests') r WHERE r->>'id'=rid::text;
 -- Identical UUIDs across independent systems do not identify the same person.
 ASSERT (row->>'approval_ready')::boolean,'Office/POS IDs remain separate identities';
 UPDATE public.inventory_purchase_requests SET created_actor=buyer WHERE id=rid;
 page:=public.procurement_approval_inbox_batch(scopes);
 SELECT r INTO row FROM jsonb_array_elements(page->'requests') r WHERE r->>'id'=rid::text;
 ASSERT row->'approval_blockers' ? 'PROCUREMENT_APPROVAL_NOT_PERMITTED';
 UPDATE public.inventory_purchase_requests SET created_actor=jsonb_build_object('system','pos','subject_id',test_uuid(1)) WHERE id=rid;

 -- Legacy policy 2 uses the exact historical commercial hash, evaluated in a set.
 UPDATE public.inventory_purchase_requests SET approval_policy_version=2,brand_approved_actor=jsonb_build_object('system','pos','subject_id',test_uuid(3)) WHERE id=rid;
 UPDATE public.inventory_purchase_requests SET brand_approval_hash=public.procurement_brand_hash(rid) WHERE id=rid;
 SELECT approval_blockers INTO blockers FROM public.procurement_buyer_readiness(ARRAY[rid]);
 ASSERT NOT(blockers ? 'PROCUREMENT_BRAND_APPROVAL_REQUIRED');
 UPDATE public.inventory_purchase_requests SET brand_approval_hash='stale' WHERE id=rid;
 SELECT approval_blockers INTO blockers FROM public.procurement_buyer_readiness(ARRAY[rid]);
 ASSERT blockers ? 'PROCUREMENT_BRAND_APPROVAL_REQUIRED';
 UPDATE public.inventory_purchase_requests SET approval_policy_version=3 WHERE id=rid;
 SELECT count(*) INTO before_count FROM public.procurement_command_results;
 result:=public.procurement_command(test_uuid(101),'office_approve',rid,1,'readiness-ready','{}',buyer);
 ASSERT result->>'status'='approved','Readiness agrees with the real policy-3 command';
 ASSERT public.procurement_command(test_uuid(101),'office_approve',rid,1,'readiness-ready','{}',buyer)=result,'Idempotent retry';
 ASSERT (SELECT count(*) FROM public.procurement_command_results)=before_count+1;
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.procurement_approval_inbox_batch(scopes)->'requests') r WHERE r->>'id'=rid::text),'Approved request leaves the inbox';
 ASSERT NOT has_function_privilege('authenticated','public.procurement_buyer_readiness(uuid[])','EXECUTE');
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM public.test_expect_error(format('SELECT public.procurement_approval_inbox_batch(%L::jsonb)',scopes),'PROCUREMENT_SCOPE_FORBIDDEN');
 RAISE NOTICE 'PASS: buyer readiness, quote absence/selection/expiry/coverage/comparison, detail parity, counts, native IDs, SoD, policy 2 history, policy 3 final approval and retry';
END $test$;
ROLLBACK;
