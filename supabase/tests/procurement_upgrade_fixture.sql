-- Capture actual pre-migration approval and accounting hashes, not reconstructed expectations.
CREATE TABLE public.test_procurement_upgrade_state(request_id uuid,approval_hash text,purchase_order_id uuid,snapshot jsonb);
DO $fixture$
DECLARE buyer jsonb:=jsonb_build_object('system','office','subject_id',test_uuid(9701),'store_id',test_uuid(101),'can_manage',true,'can_create',true,'can_office_approve',true,'can_view_prices',true);
 r jsonb;rid uuid;lid uuid;qid uuid;po uuid;i integer;senior jsonb;
BEGIN
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 PERFORM public.procurement_command(test_uuid(101),'configure',NULL,0,'upgrade-policy','{"enabled":true,"high_value_amount":1000000,"max_price_increase_percent":20,"quantity_review_multiplier":100}',buyer);
 FOR i IN 1..2 LOOP
 r:=public.procurement_command(test_uuid(101),'create_request',NULL,0,'upgrade-pr-'||i,jsonb_build_object('reason','In-flight request','requested_delivery_date',current_date+2,'lines',jsonb_build_array(jsonb_build_object('product_id',test_uuid(301),'quantity',10,'unit','g'))),buyer);rid:=(r->>'id')::uuid;
 r:=public.procurement_command(test_uuid(101),'submit_request',rid,1,'upgrade-submit-'||i,'{}',buyer);
 PERFORM set_config('request.jwt.claim.role','authenticated',true);PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
 r:=public.procurement_command(test_uuid(101),'store_approve',rid,2,'upgrade-store-'||i);
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 SELECT id INTO lid FROM public.inventory_purchase_request_lines WHERE request_id=rid AND active;
 r:=public.procurement_command(test_uuid(101),'save_quote',rid,3,'upgrade-quote-'||i,jsonb_build_object('supplier_id',test_uuid(201),'valid_until',current_date+2,'delivery_date',current_date+2,'payment_terms','Net 7','evidence_reference','Written quote','lines',jsonb_build_array(jsonb_build_object('request_line_id',lid,'supplier_item_id',test_uuid(401),'quantity_base',10,'unit_price',100,'tax_rate',0))),buyer);
 SELECT id INTO qid FROM public.procurement_quotes WHERE request_id=rid;
 r:=public.procurement_command(test_uuid(101),'select_quote',rid,4,'upgrade-select-'||i,jsonb_build_object('quote_id',qid,'reason','Existing supplier'),buyer);
 r:=public.procurement_command(test_uuid(101),'office_approve',rid,5,'upgrade-approve-'||i,'{}',buyer);
 IF r->>'status'='senior_review' THEN senior:=buyer||jsonb_build_object('subject_id',test_uuid(9702),'can_senior_approve',true);r:=public.procurement_command(test_uuid(101),'senior_approve',rid,(r->>'row_version')::integer,'upgrade-senior-'||i,'{}',senior);END IF;
 ASSERT r->>'status'='approved';
 INSERT INTO public.test_procurement_upgrade_state(request_id,approval_hash) VALUES(rid,r->>'approval_hash');
 IF i=2 THEN
 r:=public.procurement_command(test_uuid(101),'issue_po',rid,(r->>'row_version')::integer,'upgrade-issue-2',jsonb_build_object('quote_id',qid,'delivery_address','Store address','contact_name','Receiver'),buyer);po:=(r->'purchase_order'->>'id')::uuid;
 UPDATE public.test_procurement_upgrade_state SET purchase_order_id=po,snapshot=public.procurement_order_snapshot(test_uuid(101),po,buyer) WHERE request_id=rid;
 END IF;
 END LOOP;
END $fixture$;
