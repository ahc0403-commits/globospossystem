BEGIN;
DO $test$
DECLARE r jsonb;rid uuid;lid uuid;added uuid:=test_uuid(28001);foreign_product uuid:=test_uuid(28002);
 payload jsonb;before_actor jsonb;before_snapshot jsonb;before_version integer;events_before bigint;
BEGIN
 UPDATE public.procurement_store_policies SET enabled=true,two_stage_required=true,new_requests_enabled=true WHERE restaurant_id=test_uuid(101);
 INSERT INTO public.inventory_products(id,restaurant_id,name,base_unit,stock_unit,base_unit_factor,is_active,is_orderable,product_code)
 VALUES(added,test_uuid(101),'Added material','g','kg',1000,true,true,'ADD-001'),
       (foreign_product,test_uuid(102),'Foreign material','g','kg',1000,true,true,'OTHER-001');
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 r:=public.procurement_command(test_uuid(101),'create_request',NULL,0,'adjust-create',jsonb_build_object('reason','Restock','requested_delivery_date',current_date+2,'lines',jsonb_build_array(jsonb_build_object('product_id',test_uuid(301),'quantity',10,'unit','g'))));
 rid:=(r->>'id')::uuid;
 SELECT id,to_jsonb(l) INTO lid,before_snapshot FROM public.inventory_purchase_request_lines l WHERE request_id=rid AND active;
 SELECT created_actor INTO before_actor FROM public.inventory_purchase_requests WHERE id=rid;
 r:=public.procurement_command(test_uuid(101),'submit_request',rid,1,'adjust-submit');
 payload:=jsonb_build_object('reason','Add registered item','lines',jsonb_build_array(jsonb_build_object('request_line_id',lid,'quantity',12)),
   'new_lines',jsonb_build_array(jsonb_build_object('product_id',added,'quantity',2,'unit','kg')));
 -- The requester cannot turn an adjustment payload into manager authority.
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,2,%L,%L::jsonb)',test_uuid(101),'adjust_request',rid,'adjust-requester',payload),'PROCUREMENT_SELF_APPROVAL_FORBIDDEN');
 PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
 ASSERT public.procurement_workspace_page(test_uuid(101),'{"request_view":true}')->>'adjustment_additions_version'='1','Page advertises only the installed atomic adjustment contract';
 SELECT count(*) INTO events_before FROM public.procurement_events WHERE record_id=rid;
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,2,%L,%L::jsonb)',test_uuid(101),'adjust_request',rid,'adjust-foreign',jsonb_set(payload,'{new_lines,0,product_id}',to_jsonb(foreign_product::text))),'PROCUREMENT_PRODUCT_INVALID');
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,2,%L,%L::jsonb)',test_uuid(101),'adjust_request',rid,'adjust-unit',jsonb_set(payload,'{new_lines,0,unit}','"box"')),'PROCUREMENT_UNIT_INVALID');
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,2,%L,%L::jsonb)',test_uuid(101),'adjust_request',rid,'adjust-zero',jsonb_set(payload,'{new_lines,0,quantity}','0')),'PROCUREMENT_QUANTITY_INVALID');
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,2,%L,%L::jsonb)',test_uuid(101),'adjust_request',rid,'adjust-bound',jsonb_set(payload,'{new_lines}',(SELECT jsonb_agg(payload->'new_lines'->0) FROM generate_series(1,200)))),'PROCUREMENT_LINES_REQUIRED');
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,2,%L,%L::jsonb)',test_uuid(101),'adjust_request',rid,'adjust-duplicate',jsonb_set(payload,'{new_lines}',(payload->'new_lines')||(payload->'new_lines'))),'PROCUREMENT_LINE_INVALID');
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,2,%L,%L::jsonb)',test_uuid(101),'adjust_request',rid,'adjust-existing-product',jsonb_set(payload,'{new_lines,0,product_id}',to_jsonb(test_uuid(301)::text))),'PROCUREMENT_LINE_INVALID');
 UPDATE public.inventory_products SET is_active=false WHERE id=added;
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,2,%L,%L::jsonb)',test_uuid(101),'adjust_request',rid,'adjust-inactive',payload),'PROCUREMENT_PRODUCT_INVALID');
 UPDATE public.inventory_products SET is_active=true WHERE id=added;
 UPDATE public.inventory_products SET is_orderable=false WHERE id=added;
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,2,%L,%L::jsonb)',test_uuid(101),'adjust_request',rid,'adjust-unorderable',payload),'PROCUREMENT_PRODUCT_INVALID');
 UPDATE public.inventory_products SET is_orderable=true WHERE id=added;
 ASSERT (SELECT requested_quantity=10 FROM public.inventory_purchase_request_lines WHERE id=lid),'Invalid additions roll back quantity edits';
 ASSERT (SELECT count(*)=1 FROM public.inventory_purchase_request_lines WHERE request_id=rid AND active),'Invalid additions insert nothing';
 ASSERT (SELECT row_version=2 FROM public.inventory_purchase_requests WHERE id=rid),'Invalid batch preserves version';
 ASSERT (SELECT count(*)=events_before FROM public.procurement_events WHERE record_id=rid),'Invalid batch adds no audit event';
 r:=public.procurement_command(test_uuid(101),'adjust_request',rid,2,'adjust-success',payload);
 ASSERT r->>'status'='submitted' AND (r->>'row_version')::integer=3;
 ASSERT jsonb_array_length(r->'lines')=2,'Command result and audit include complete adjusted lines';
 ASSERT (SELECT requested_quantity=12 AND conversion_snapshot=(before_snapshot->>'conversion_snapshot')::numeric
   AND product_name_snapshot IS NOT DISTINCT FROM before_snapshot->>'product_name_snapshot' FROM public.inventory_purchase_request_lines WHERE id=lid),'Original identity and snapshots survive';
 ASSERT (SELECT requested_quantity=2 AND requested_unit='kg' AND quantity_base=2000 AND conversion_snapshot=1000
   AND product_code_snapshot='ADD-001' AND estimated_unit_price IS NULL FROM public.inventory_purchase_request_lines WHERE request_id=rid AND product_id=added),'New line uses registered conversion and never invents a price';
 ASSERT (SELECT created_actor=before_actor FROM public.inventory_purchase_requests WHERE id=rid),'Requester audit identity is unchanged';
 ASSERT (SELECT jsonb_array_length(previous_state->'lines')=1 AND jsonb_array_length(next_state->'lines')=2
   FROM public.procurement_events WHERE record_id=rid AND action='adjust_request'),'Before/after audit records the addition';
 ASSERT public.procurement_command(test_uuid(101),'adjust_request',rid,2,'adjust-success',payload)=r,'Same retry returns the original result';
 ASSERT (SELECT count(*)=2 FROM public.inventory_purchase_request_lines WHERE request_id=rid AND active),'Retry cannot duplicate items';
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,2,%L,%L::jsonb)',test_uuid(101),'adjust_request',rid,'adjust-stale',payload),'PROCUREMENT_STALE_VERSION');
 -- Legacy quantity-only payload is still accepted under the same command.
 r:=public.procurement_command(test_uuid(101),'adjust_request',rid,3,'adjust-legacy',payload-'new_lines');
 r:=public.procurement_command(test_uuid(101),'store_approve',rid,4,'adjust-approve');
 ASSERT r->>'status'='office_review';
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,5,%L,%L::jsonb)',test_uuid(101),'adjust_request',rid,'adjust-after-approval',payload),'PROCUREMENT_STORE_APPROVAL_FORBIDDEN');
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,5,%L,%L::jsonb)',test_uuid(102),'adjust_request',rid,'adjust-cross-store',payload),'PROCUREMENT_SCOPE_FORBIDDEN');
 ASSERT NOT has_function_privilege('authenticated','public.procurement_insert_adjustment_lines(uuid,uuid,jsonb)','EXECUTE');
 ASSERT NOT has_function_privilege('service_role','public.procurement_insert_adjustment_lines(uuid,uuid,jsonb)','EXECUTE');
END $test$;
ROLLBACK;
