BEGIN;
DO $pr_account$
DECLARE buyer jsonb:=jsonb_build_object('system','office','subject_id',test_uuid(77001),'store_id',test_uuid(101),'can_manage',true,'can_create',true,'can_office_approve',true,'can_view_prices',true);
 config jsonb; r jsonb; edited jsonb; page jsonb; next_page jsonb; last jsonb; payload jsonb; rid uuid; old_id uuid; new_id uuid; qty numeric; price numeric;
BEGIN
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 SELECT to_jsonb(p) INTO config FROM public.procurement_store_policies p WHERE restaurant_id=test_uuid(101);
 PERFORM public.procurement_command(test_uuid(101),'configure',NULL,COALESCE((config->>'row_version')::integer,0),'pr-account-policy','{"enabled":true,"new_requests_enabled":true,"three_stage_required":true,"high_value_amount":1000000,"max_price_increase_percent":20,"quantity_review_multiplier":100}',buyer);
 UPDATE public.inventory_supplier_items SET is_preferred=false WHERE product_id=test_uuid(301);
 UPDATE public.inventory_supplier_items SET is_preferred=true,unit_price=85000,tax_rate=0 WHERE id=test_uuid(401);
 SELECT order_unit_quantity_base INTO qty FROM public.inventory_supplier_items WHERE id=test_uuid(401);
 payload:=jsonb_build_object('reason','PR account beverage','requested_delivery_date',current_date+2,'purchase_category','beverage','purchase_channel','shopee',
   'lines',jsonb_build_array(jsonb_build_object('product_id',test_uuid(301),'quantity',20,'unit','g')));
 PERFORM set_config('request.jwt.claim.role','authenticated',true);PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 r:=public.procurement_command(test_uuid(101),'create_request',NULL,0,'pr-account-create',payload);rid:=(r->>'id')::uuid;
 ASSERT r->>'purchase_category'='beverage';
 ASSERT (SELECT estimated_unit_price FROM public.inventory_purchase_request_lines WHERE request_id=rid AND active)=85000,'Automatic estimate works without supplier selection';
 ASSERT (SELECT preferred_supplier_id IS NULL FROM public.inventory_purchase_request_lines WHERE request_id=rid AND active),'Automatic estimate does not select the final supplier';
 UPDATE public.inventory_supplier_items SET unit_price=90000 WHERE id=test_uuid(401);
 ASSERT public.procurement_command(test_uuid(101),'create_request',NULL,0,'pr-account-create',payload)=r,'Exact retry recovers the original PR after master changes';
 payload:=jsonb_set(payload-'purchase_channel','{lines,0,quantity}','25'::jsonb)
   ||jsonb_build_object('reason','PR account beverage edited','requested_delivery_date',current_date+3);
 edited:=public.procurement_command(test_uuid(101),'save_request',rid,1,'pr-account-save',payload);
 ASSERT edited->>'purchase_channel'='shopee','Hidden channel survives an edit even when omitted';
 ASSERT (edited->>'row_version')::integer=2;
 ASSERT edited->>'reason'='PR account beverage edited';
 ASSERT edited->>'requested_delivery_date'=(current_date+3)::text;
 ASSERT (SELECT requested_quantity FROM public.inventory_purchase_request_lines WHERE request_id=rid AND active)=25,'Edited quantity is stored';
 ASSERT (SELECT estimated_unit_price FROM public.inventory_purchase_request_lines WHERE request_id=rid AND active)=90000;
 ASSERT public.procurement_document_data(test_uuid(101),'pr',rid,'internal')->'data'->'lines'->0 ? 'estimated_amount';
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,1,%L,%L::jsonb)',test_uuid(101),'save_request',rid,'pr-account-stale',payload),'PROCUREMENT_STALE_VERSION');
 PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,2,%L,%L::jsonb)',test_uuid(101),'cancel_request',rid,'pr-account-foreign-cancel','{"reason":"delete"}'),'PROCUREMENT_CANCEL_FORBIDDEN');
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 r:=public.procurement_command(test_uuid(101),'cancel_request',rid,2,'pr-account-delete','{"reason":"deleted_before_submit"}');
 ASSERT r->>'status'='cancelled';
 page:=public.procurement_workspace_page(test_uuid(101),'{"search":"PR account beverage","request_group":"pending","purchase_category":"beverage","request_sort":"created","request_view":true}');
 ASSERT jsonb_array_length(page->'requests')=0;
 ASSERT (page->'request_counts'->>'cancelled')::integer=1,'Counts cover all filtered statuses, not the current page';
 ASSERT jsonb_array_length(page->'orders')=0,'PR-only view does not load unrelated POs';
 page:=public.procurement_workspace_page(test_uuid(101),'{"search":"PR account beverage","request_group":"cancelled","purchase_category":"beverage"}');
 ASSERT page->'requests'->0->>'id'=rid::text;
 ASSERT EXISTS(SELECT 1 FROM public.procurement_events WHERE record_id=rid AND action='cancel_request');
 -- Two equally preferred price sources cannot silently choose a supplier.
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 INSERT INTO public.inventory_suppliers(id,supplier_name) VALUES(test_uuid(77003),'Second estimate supplier');
 INSERT INTO public.inventory_supplier_items(id,supplier_id,product_id,order_unit,order_unit_quantity_base,min_order_quantity,unit_price,tax_rate,is_preferred)
 VALUES(test_uuid(77002),test_uuid(77003),test_uuid(301),'g',1,1,100,0,true);
 PERFORM set_config('request.jwt.claim.role','authenticated',true);
 r:=public.procurement_command(test_uuid(101),'create_request',NULL,0,'pr-account-ambiguous',payload);
 ASSERT (SELECT estimated_unit_price IS NULL FROM public.inventory_purchase_request_lines WHERE request_id=(r->>'id')::uuid AND active),'Ambiguous estimates need a quote';
 rid:=(r->>'id')::uuid;
 r:=public.procurement_command(test_uuid(101),'submit_request',rid,1,'pr-account-submit','{}');
 ASSERT r->>'status'='submitted';
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,2,%L,%L::jsonb)',test_uuid(101),'save_request',rid,'pr-account-submitted-save',payload),'PROCUREMENT_REQUEST_NOT_EDITABLE');
 PERFORM public.test_expect_error(format('SELECT public.procurement_command(%L,%L,%L,2,%L,%L::jsonb)',test_uuid(101),'cancel_request',rid,'pr-account-submitted-delete','{"reason":"delete"}'),'PROCUREMENT_CANCEL_FORBIDDEN');
 -- Created-at pagination stays stable when an older document has a more recent update.
 INSERT INTO public.inventory_purchase_requests(id,restaurant_id,source,requested_delivery_date,reason,created_actor,created_at,updated_at,purchase_category)
 SELECT test_uuid(78000+n),test_uuid(101),'pos',current_date,'PR account pages','{}','2026-10-01T00:00:00Z'::timestamptz+n*interval '1 minute','2026-10-01T00:00:00Z'::timestamptz+n*interval '1 minute',CASE WHEN n%2=0 THEN 'tools' ELSE 'stationery' END FROM generate_series(1,55)n;
 UPDATE public.inventory_purchase_requests SET updated_at='2026-12-01' WHERE id=test_uuid(78001);
 page:=public.procurement_workspace_page(test_uuid(101),'{"search":"PR account pages","request_sort":"created","purchase_category":"tools"}');
 ASSERT page->'requests'->0->>'id'=test_uuid(78055)::text;
 ASSERT (page->'request_counts'->>'pending')::integer=55;
 last:=page->'requests'->19;
 next_page:=public.procurement_workspace_page(test_uuid(101),jsonb_build_object('search','PR account pages','request_sort','created','purchase_category','tools','request_before',last->>'created_at','request_before_id',last->>'id'));
 ASSERT jsonb_array_length(next_page->'requests')=20;
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(page->'requests') a JOIN jsonb_array_elements(next_page->'requests') b ON a->>'id'=b->>'id');
 ASSERT public.procurement_workspace_page(test_uuid(101),'{"search":"PR account pages"}')->'requests'->0->>'id'=test_uuid(78001)::text,'Legacy Office callers retain updated-at ordering';
 PERFORM public.test_expect_error(format('SELECT public.procurement_workspace_page(%L,%L::jsonb)',test_uuid(101),'{"purchase_category":"unknown"}'),'PROCUREMENT_FILTER_INVALID');
 PERFORM public.test_expect_error(format('SELECT public.procurement_workspace_page(%L,%L::jsonb)',test_uuid(102),'{}'),'PROCUREMENT_SCOPE_FORBIDDEN');
 RAISE NOTICE 'PASS: PR automatic/ambiguous estimates, exact retry, hidden channel, draft save/delete, ownership, beverage, grouped counts, created cursors and Office compatibility';
END $pr_account$;
ROLLBACK;
