BEGIN;
INSERT INTO public.inventory_purchase_requests(id,restaurant_id,source,requested_delivery_date,reason,created_actor)
 SELECT test_uuid(20000+n),test_uuid(101),'pos',current_date,'Page fixture',jsonb_build_object('system','pos','subject_id',test_uuid(1)) FROM generate_series(1,100) n;
INSERT INTO public.inventory_products(id,restaurant_id,product_code,name,stock_unit,base_unit,base_unit_factor,receipt_classification)
 SELECT test_uuid(21000+n),test_uuid(101),'PAGE-'||n,'Page product '||n,'ea','ea',1,'nonstock' FROM generate_series(1,200) n;
INSERT INTO public.inventory_purchase_request_lines(request_id,product_id,requested_quantity,requested_unit,quantity_base,conversion_snapshot)
 SELECT test_uuid(20001),test_uuid(21000+n),1,'ea',1,1 FROM generate_series(1,200) n;
INSERT INTO public.procurement_events(restaurant_id,record_id,action,actor)
 SELECT test_uuid(101),test_uuid(20001),'fixture',jsonb_build_object('system','pos','subject_id',test_uuid(1)) FROM generate_series(1,10000);
INSERT INTO public.inventory_purchase_requests(id,restaurant_id,source,requested_delivery_date,reason,created_actor,created_at)
 VALUES(test_uuid(22001),test_uuid(101),'pos',current_date,'Local date boundary','{}','2026-10-04T16:59:59Z'),
 (test_uuid(22002),test_uuid(101),'pos',current_date,'Local date boundary','{}','2026-10-04T17:00:00Z');
DO $pages$
DECLARE page jsonb;next_page jsonb;detail jsonb;last jsonb;
BEGIN
 PERFORM set_config('request.jwt.claim.role','authenticated',true);PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 page:=public.procurement_workspace_page(test_uuid(101),'{}');ASSERT jsonb_array_length(page->'requests')=20;ASSERT (page->>'request_has_more')::boolean;
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(page->'requests') r WHERE jsonb_array_length(r->'lines')<>0 OR jsonb_array_length(r->'quotes')<>0);
 last:=page->'requests'->19;
 next_page:=public.procurement_workspace_page(test_uuid(101),jsonb_build_object('request_before',last->>'updated_at','request_before_id',last->>'id'));
 ASSERT jsonb_array_length(next_page->'requests')=20;
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(page->'requests') a JOIN jsonb_array_elements(next_page->'requests') b ON a->>'id'=b->>'id');
 ASSERT jsonb_array_length(public.procurement_workspace_page(test_uuid(101),'{"limit":100}')->'requests')=50;
 detail:=public.procurement_workspace_page(test_uuid(101),jsonb_build_object('request_id',test_uuid(20001)));
 ASSERT jsonb_array_length(detail->'request_detail'->'lines')=200;ASSERT jsonb_array_length(detail->'events')=100;ASSERT (detail->>'event_has_more')::boolean;
 last:=detail->'events'->99;
 next_page:=public.procurement_workspace_page(test_uuid(101),jsonb_build_object('request_id',test_uuid(20001),'event_before',last->>'created_at','event_before_id',last->>'id'));
 ASSERT jsonb_array_length(next_page->'events')=100;
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(detail->'events') a JOIN jsonb_array_elements(next_page->'events') b ON a->>'id'=b->>'id');
 ASSERT octet_length(detail::text)<300000,'A selected 200-line request and 100-event page stays bounded';
 page:=public.procurement_workspace_page(test_uuid(101),'{"search":"Local date boundary","created_from":"2026-10-05","created_to":"2026-10-05"}');
 ASSERT jsonb_array_length(page->'requests')=1;ASSERT page->'requests'->0->>'id'=test_uuid(22002)::text,'Date filters use Vietnam midnight';
 RAISE NOTICE 'PASS: 100 requests, 200 selected lines, 10000 events, keyset pagination, 50-row cap, summary/detail split';
END $pages$;
ROLLBACK;
