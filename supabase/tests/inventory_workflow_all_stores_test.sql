-- Executed against a disposable PostgreSQL database by the repository test runner.
INSERT INTO public.brands VALUES(test_uuid(901)),(test_uuid(902));
INSERT INTO public.restaurants(id,brand_id,tax_entity_id,name) VALUES
(test_uuid(101),test_uuid(901),test_uuid(801),'Operating A'),
(test_uuid(102),test_uuid(902),test_uuid(802),'Operating B'),
(test_uuid(103),test_uuid(901),test_uuid(801),'Future store');
INSERT INTO auth.users SELECT test_uuid(i) FROM generate_series(1,9) i;
INSERT INTO public.users(id,auth_id,role,restaurant_id,full_name,extra_permissions) VALUES
(test_uuid(1),test_uuid(1),'inventory_orderer',test_uuid(101),'Orderer A','{}'),
(test_uuid(2),test_uuid(2),'store_admin',test_uuid(101),'Store A','{}'),
(test_uuid(3),test_uuid(3),'brand_admin',test_uuid(101),'Brand A',ARRAY['inventory_purchase_urgent_approve']),
(test_uuid(4),test_uuid(4),'inventory_accounting',test_uuid(101),'Accounting A','{}'),
(test_uuid(5),test_uuid(5),'inventory_orderer',test_uuid(102),'Orderer B','{}'),
(test_uuid(6),test_uuid(6),'store_admin',test_uuid(102),'Store B','{}'),
(test_uuid(7),test_uuid(7),'brand_admin',test_uuid(102),'Brand B','{}'),
(test_uuid(8),test_uuid(8),'inventory_accounting',test_uuid(102),'Accounting B','{}'),
(test_uuid(9),test_uuid(9),'inventory_orderer',test_uuid(103),'New store orderer','{}');
INSERT INTO public.user_tax_entity_access VALUES(test_uuid(4),test_uuid(801),true),(test_uuid(8),test_uuid(802),true);
INSERT INTO public.inventory_suppliers(id,supplier_name) VALUES(test_uuid(201),'Shared supplier');
INSERT INTO public.inventory_items(id,restaurant_id) VALUES(test_uuid(501),test_uuid(101)),(test_uuid(502),test_uuid(102));
INSERT INTO public.inventory_products(id,restaurant_id,name,inventory_item_id) VALUES
(test_uuid(301),test_uuid(101),'A item',test_uuid(501)),
(test_uuid(302),test_uuid(102),'B item',test_uuid(502));
INSERT INTO public.inventory_supplier_items(id,supplier_id,product_id,order_unit,order_unit_quantity_base,unit_price) VALUES
(test_uuid(401),test_uuid(201),test_uuid(301),'box',10,100),
(test_uuid(402),test_uuid(201),test_uuid(302),'box',10,200);
INSERT INTO storage.objects(bucket_id,name,metadata,owner_id) VALUES
('inventory-receipt-statements',test_uuid(101)||'/'||test_uuid(701)||'/receipt.pdf','{"mimetype":"application/pdf","size":120}',test_uuid(1)::text),
('inventory-receipt-statements',test_uuid(101)||'/'||test_uuid(702)||'/receipt.pdf','{"mimetype":"application/pdf","size":120}',test_uuid(1)::text),
('inventory-receipt-statements',test_uuid(101)||'/'||test_uuid(703)||'/receipt.pdf','{"mimetype":"application/pdf","size":120}',test_uuid(2)::text);
INSERT INTO public.inventory_purchase_orders(purchase_order_no,restaurant_id,supplier_id,status,created_at)
SELECT 'history-'||i,test_uuid(101),test_uuid(201),'ordered',now() FROM generate_series(1,300) i;
INSERT INTO public.inventory_purchase_orders(id,purchase_order_no,restaurant_id,supplier_id,status,created_at)
VALUES(test_uuid(601),'old-pending',test_uuid(101),test_uuid(201),'submitted','2020-01-01');
CREATE FUNCTION public.test_expect_error(p_sql text,p_error text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN EXECUTE p_sql;
  EXCEPTION WHEN OTHERS THEN
    IF position(p_error in SQLERRM)>0 THEN RETURN; END IF;
    RAISE;
  END;
  RAISE EXCEPTION 'Expected %, but succeeded: %',p_error,p_sql;
END $$;
GRANT EXECUTE ON FUNCTION public.test_expect_error(text,text) TO authenticated;

SET ROLE authenticated;
DO $test$
DECLARE po public.inventory_purchase_orders%ROWTYPE; po2 public.inventory_purchase_orders%ROWTYPE;
  page jsonb; detail jsonb; payload jsonb; result jsonb; repeated jsonb;
  lines jsonb; line_id uuid; i integer; receipt_path text; version integer;
BEGIN
  PERFORM set_config('request.jwt.claim.sub',test_uuid(999)::text,true);
  ASSERT public.can_access_inventory_workflow(test_uuid(101)) IS FALSE, 'Unknown users must fail closed, not return NULL';
  PERFORM public.test_expect_error(format('SELECT public.get_inventory_workflow_detail(%L)',test_uuid(601)), 'INVENTORY_PURCHASE_FORBIDDEN');
  PERFORM public.test_expect_error(format('SELECT public.store_decide_inventory_purchase_order(%L,1,true,NULL)',test_uuid(601)), 'INVENTORY_PURCHASE_STORE_APPROVAL_FORBIDDEN');
  PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
  ASSERT public.can_access_inventory_workflow(test_uuid(101));
  ASSERT NOT public.can_access_inventory_workflow(test_uuid(102));
  ASSERT NOT public.can_access_inventory_purchase_store(test_uuid(101));
  ASSERT (SELECT count(*) FROM storage.objects WHERE bucket_id='inventory-receipt-statements')=3, 'Orderer can read scoped receipt attachments';
  INSERT INTO storage.objects(bucket_id,name,metadata,owner_id) VALUES
    ('inventory-receipt-statements',test_uuid(101)||'/'||test_uuid(799)||'/allowed.pdf','{"mimetype":"application/pdf","size":10}',test_uuid(1)::text);
  PERFORM public.test_expect_error(format('INSERT INTO storage.objects(bucket_id,name) VALUES(%L,%L)',
    'inventory-receipt-statements',test_uuid(102)||'/'||test_uuid(799)||'/denied.pdf'),'row-level security');
  ASSERT (SELECT count(*) FROM public.inventory_supplier_items)=0, 'Legacy permissive price read must be closed';
  ASSERT (SELECT count(*) FROM public.inventory_supplier_item_price_history)=0;
  PERFORM public.test_expect_error(format('SELECT public.upsert_inventory_supplier_item(%L)',test_uuid(101)), 'INVENTORY_SUPPLIER_ITEM_FORBIDDEN');
  PERFORM public.test_expect_error(format('SELECT public.bulk_upsert_inventory_ingredients(%L,%L::jsonb)',test_uuid(101),'[]'), 'INVENTORY_INGREDIENT_IMPORT_FORBIDDEN');
  PERFORM public.test_expect_error(format('SELECT public.get_inventory_cost_analysis(%L)',test_uuid(101)), 'INVENTORY_COST_ANALYSIS_FORBIDDEN');
  PERFORM public.test_expect_error(format('SELECT public.bulk_update_inventory_supplier_prices(%L,%L::jsonb,false)',test_uuid(101),'[]'), 'INVENTORY_PRICE_IMPORT_FORBIDDEN');

  page:=public.get_inventory_order_catalog(test_uuid(101));
  ASSERT jsonb_array_length(page->'items')=1;
  ASSERT NOT ((page->'items'->0) ? 'unit_price');
  PERFORM public.test_expect_error(format('SELECT public.get_inventory_order_catalog(%L)',test_uuid(102)), 'INVENTORY_PURCHASE_FORBIDDEN');
  page:=public.get_inventory_workflow_orders(test_uuid(101),ARRAY['submitted'],false,0,80);
  ASSERT jsonb_array_length(page->'orders')=1 AND page->'orders'->0->>'id'=test_uuid(601)::text;
  ASSERT (page->'counts'->>'ordered')::int=300;
  page:=public.get_inventory_workflow_orders(test_uuid(101),ARRAY['ordered'],false,240,80);
  ASSERT jsonb_array_length(page->'orders')=60 AND (page->>'total')::int=300;
  -- Actual database role checks, rather than string matching the source.
  lines:=jsonb_build_array(jsonb_build_object('supplier_item_id',test_uuid(401),'ordered_quantity_unit',2,'unit_price',1));
  po:=public.create_manual_inventory_purchase_order(test_uuid(101),test_uuid(201),lines,current_date,NULL);
  page:=public.get_inventory_workflow_orders(test_uuid(101),ARRAY['draft','submitted'],false,0,80);
  ASSERT page->'orders'->0->>'id'=test_uuid(601)::text, 'Oldest pending order must remain first';
  detail:=public.get_inventory_workflow_detail(po.id);
  ASSERT (detail->'lines'->0->>'unit_price')::numeric=100, 'Orderer cannot choose master price';
  ASSERT NOT ((detail->'lines'->0) ? 'recommendation_snapshot');
  ASSERT (SELECT count(*) FROM public.inventory_purchase_order_lines)=0, 'Raw recommendation snapshot is not exposed';
  PERFORM public.test_expect_error(format('SELECT public.create_manual_inventory_purchase_order(%L,%L,%L::jsonb,current_date,NULL)',
    test_uuid(101),test_uuid(201),jsonb_build_array(jsonb_build_object('supplier_item_id',test_uuid(402),'ordered_quantity_unit',1))),
    'INVENTORY_PURCHASE_SUPPLIER_ITEM_NOT_FOUND');
  FOR i IN 1..3 LOOP
    PERFORM set_config('request.jwt.claim.sub',test_uuid(i)::text,true);
    po:=public.create_manual_inventory_purchase_order(test_uuid(101),test_uuid(201),lines,current_date,NULL);
    po:=public.submit_inventory_purchase_order(po.id,po.row_version);
    PERFORM public.test_expect_error(format('SELECT public.brand_decide_inventory_purchase_order(%L,%s,true,NULL)',po.id,po.row_version),
      CASE WHEN i=3 THEN 'INVENTORY_PURCHASE_INVALID_TRANSITION' ELSE 'INVENTORY_PURCHASE_BRAND_APPROVAL_FORBIDDEN' END);
    PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
    PERFORM public.test_expect_error(format('SELECT public.store_decide_inventory_purchase_order(%L,NULL,true,NULL)',po.id),
      'INVENTORY_PURCHASE_STALE_VERSION');
    version:=po.row_version;
    po:=public.store_decide_inventory_purchase_order(po.id,po.row_version,true,NULL);
    PERFORM public.test_expect_error(format('SELECT public.store_decide_inventory_purchase_order(%L,%s,true,NULL)',po.id,version),
      'INVENTORY_PURCHASE_INVALID_TRANSITION');
    PERFORM set_config('request.jwt.claim.sub',test_uuid(3)::text,true);
    po:=public.brand_decide_inventory_purchase_order(po.id,po.row_version,true,NULL);
    ASSERT po.status='ordered' AND po.approval_snapshot_hash IS NOT NULL;
    ASSERT (SELECT count(*) FROM public.inventory_purchase_documents WHERE purchase_order_id=po.id)=1;
  END LOOP;
  -- A second operating store uses the exact same policy, independent of pilot identifiers.
  PERFORM set_config('request.jwt.claim.sub',test_uuid(6)::text,true);
  po2:=public.create_manual_inventory_purchase_order(test_uuid(102),test_uuid(201),
    jsonb_build_array(jsonb_build_object('supplier_item_id',test_uuid(402),'ordered_quantity_unit',1)),current_date,NULL);
  po2:=public.submit_inventory_purchase_order(po2.id,po2.row_version);
  po2:=public.store_decide_inventory_purchase_order(po2.id,po2.row_version,true,NULL);
  PERFORM set_config('request.jwt.claim.sub',test_uuid(3)::text,true);
  PERFORM public.test_expect_error(format('SELECT public.brand_decide_inventory_purchase_order(%L,%s,true,NULL)',po2.id,po2.row_version),
    'INVENTORY_PURCHASE_BRAND_APPROVAL_FORBIDDEN');
  PERFORM set_config('request.jwt.claim.sub',test_uuid(7)::text,true);
  po2:=public.brand_decide_inventory_purchase_order(po2.id,po2.row_version,true,NULL);
  ASSERT po2.status='ordered';
  ASSERT NOT public.can_urgent_approve_inventory_order(test_uuid(102)), 'Urgent is explicit opt-in';
  PERFORM set_config('request.jwt.claim.sub',test_uuid(9)::text,true);
  ASSERT public.can_access_inventory_workflow(test_uuid(103)), 'New stores inherit the policy';
  PERFORM set_config('request.jwt.claim.sub',test_uuid(3)::text,true);
  po:=public.create_manual_inventory_purchase_order(test_uuid(101),test_uuid(201),lines,current_date,NULL);
  po:=public.submit_inventory_purchase_order(po.id,po.row_version);
  PERFORM public.test_expect_error(format('SELECT public.urgent_approve_inventory_purchase_order(%L,%s,%L)',po.id,po.row_version,''),
    'INVENTORY_PURCHASE_URGENT_REASON_REQUIRED');
  po:=public.urgent_approve_inventory_purchase_order(po.id,po.row_version,'Delivery deadline');
  ASSERT po.status='ordered' AND po.store_approved_by IS NULL;
  ASSERT po.approval_snapshot->'order'->>'urgent_approval_reason'='Delivery deadline';
  ASSERT (SELECT count(*) FROM public.inventory_purchase_approval_events WHERE purchase_order_id=po.id AND action='store_approval_skipped')=1;
  PERFORM public.test_expect_error(format('SELECT public.urgent_approve_inventory_purchase_order(%L,%s,%L)',po.id,po.row_version,'retry'),
    'INVENTORY_PURCHASE_INVALID_TRANSITION');
  -- Receiving submission: nullable statement number/date, rollback and replay.
  PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
  detail:=public.get_inventory_workflow_detail(po.id);
  line_id:=(detail->'lines'->0->>'id')::uuid;
  payload:=jsonb_build_array(jsonb_build_object('purchase_order_line_id',line_id,
    'received_quantity_base',10,'actual_unit_price',100,'discrepancy_reason','Partial delivery'));
  receipt_path:=test_uuid(101)||'/'||test_uuid(701)||'/receipt.pdf';
  PERFORM public.test_expect_error(format('SELECT public.submit_inventory_receipt_batch(%L,%L,%s,0,%L,%L::jsonb,%L,%L)',
    po.id,test_uuid(701),po.row_version,'capture',payload,'',receipt_path),'INVENTORY_RECEIPT_INSPECTOR_REQUIRED');
  ASSERT NOT EXISTS(SELECT 1 FROM public.inventory_receipts WHERE id=test_uuid(701)), 'Failed batch must roll back draft creation';
  PERFORM public.test_expect_error(format('SELECT public.submit_inventory_receipt_batch(%L,%L,%s,0,%L,%L::jsonb,%L,%L)',
    po.id,test_uuid(703),po.row_version,'other-uploader',payload,'Inspector',test_uuid(101)||'/'||test_uuid(703)||'/receipt.pdf'),
    'INVENTORY_RECEIPT_ATTACHMENT_REQUIRED');
  ASSERT NOT EXISTS(SELECT 1 FROM public.inventory_receipts WHERE id=test_uuid(703));
  result:=public.submit_inventory_receipt_batch(po.id,test_uuid(701),po.row_version,0,'capture',payload,'Inspector',receipt_path);
  repeated:=public.submit_inventory_receipt_batch(po.id,test_uuid(701),po.row_version,0,'capture',payload,'Inspector',receipt_path);
  ASSERT result=repeated, 'Same request must replay';
  ASSERT (SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501))=0;
  PERFORM public.test_expect_error(format('SELECT public.submit_inventory_receipt_batch(%L,%L,%s,0,%L,%L::jsonb,%L,%L)',
    po.id,test_uuid(701),po.row_version,'capture',payload,'Changed inspector',receipt_path),'INVENTORY_RECEIPT_RETRY_MISMATCH');
  PERFORM public.test_expect_error(format('SELECT public.verify_inventory_receipt(%L,%s,%L)',test_uuid(701),(result->>'row_version')::int,'verify'),
    'INVENTORY_RECEIPT_VERIFY_FORBIDDEN');
  PERFORM set_config('request.jwt.claim.sub',test_uuid(8)::text,true);
  PERFORM public.test_expect_error(format('SELECT public.verify_inventory_receipt(%L,%s,%L)',test_uuid(701),(result->>'row_version')::int,'verify'),
    'INVENTORY_RECEIPT_VERIFY_FORBIDDEN');
  PERFORM set_config('request.jwt.claim.sub',test_uuid(4)::text,true);
  po:=public.verify_inventory_receipt(test_uuid(701),(result->>'row_version')::int,'verify');
  ASSERT po.status='partially_received';
  ASSERT (SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501))=10;
  po:=public.verify_inventory_receipt(test_uuid(701),(result->>'row_version')::int,'verify');
  ASSERT (SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501))=10;
  ASSERT (SELECT count(*) FROM public.inventory_transactions WHERE reference_id=test_uuid(701))=1;
  ASSERT (SELECT note IS NOT NULL FROM public.inventory_transactions WHERE reference_id=test_uuid(701));
  RAISE NOTICE 'PASS: all-store roles, self approval, urgent audit, private pricing, old-order paging, atomic receiving, replay, accounting stock gate';
END $test$;
RESET ROLE;
INSERT INTO auth.users VALUES(test_uuid(10));
INSERT INTO public.users(id,auth_id,role,restaurant_id,full_name) VALUES(test_uuid(10),test_uuid(10),'super_admin',test_uuid(101),'Super admin');
INSERT INTO public.inventory_products(id,restaurant_id,name,inventory_item_id)
SELECT test_uuid(1300+i),test_uuid(101),'Batch ingredient '||i,test_uuid(501) FROM generate_series(1,20) i;
INSERT INTO public.inventory_supplier_items(id,supplier_id,product_id,order_unit,order_unit_quantity_base,unit_price)
SELECT test_uuid(1400+i),test_uuid(201),test_uuid(1300+i),'box',10,100 FROM generate_series(1,20) i;
SET ROLE authenticated;
DO $batch$
DECLARE po public.inventory_purchase_orders%ROWTYPE; lines jsonb; payload jsonb; invalid jsonb; detail jsonb; result jsonb; pth text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub',test_uuid(10)::text,true);
  SELECT jsonb_agg(jsonb_build_object('supplier_item_id',test_uuid(1400+i),'ordered_quantity_unit',1)) INTO lines FROM generate_series(1,20) i;
  po:=public.create_manual_inventory_purchase_order(test_uuid(101),test_uuid(201),lines,current_date,NULL);
  po:=public.submit_inventory_purchase_order(po.id,po.row_version);
  po:=public.store_decide_inventory_purchase_order(po.id,po.row_version,true,NULL);
  PERFORM public.test_expect_error(format('SELECT public.brand_decide_inventory_purchase_order(%L,%s,true,NULL)',po.id,po.row_version),
    'INVENTORY_PURCHASE_DISTINCT_APPROVER_REQUIRED');
  PERFORM set_config('request.jwt.claim.sub',test_uuid(3)::text,true);
  po:=public.brand_decide_inventory_purchase_order(po.id,po.row_version,true,NULL);
  PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
  detail:=public.get_inventory_workflow_detail(po.id);
  SELECT jsonb_agg(jsonb_build_object('purchase_order_line_id',l->>'id','received_quantity_base',10,
    'actual_unit_price',100,'discrepancy_reason','Checked')) INTO payload FROM jsonb_array_elements(detail->'lines') l;
  payload:=jsonb_set(payload,'{19,received_quantity_base}','0');
  invalid:=jsonb_set(payload,'{19,received_quantity_base}','-1');
  pth:=test_uuid(101)||'/'||test_uuid(702)||'/receipt.pdf';
  PERFORM public.test_expect_error(format('SELECT public.submit_inventory_receipt_batch(%L,%L,%s,0,%L,%L::jsonb,%L,%L)',
    po.id,test_uuid(702),po.row_version,'batch20',invalid,'Inspector',pth),'INVENTORY_RECEIPT_QUANTITY_INVALID');
  ASSERT NOT EXISTS(SELECT 1 FROM public.inventory_receipts WHERE id=test_uuid(702)), '19 valid rows + 1 error must roll back the entire batch';
  PERFORM public.test_expect_error(format('SELECT public.submit_inventory_receipt_batch(%L,%L,%s,0,%L,%L::jsonb,%L,%L)',
    po.id,test_uuid(702),po.row_version,'batch20',payload,'Inspector',replace(pth,test_uuid(101)::text,test_uuid(102)::text)),
    'INVENTORY_RECEIPT_ATTACHMENT_REQUIRED');
  result:=public.submit_inventory_receipt_batch(po.id,test_uuid(702),po.row_version,0,'batch20',payload,'Inspector',pth);
  ASSERT jsonb_array_length(public.get_inventory_workflow_detail(po.id)->'receipts'->0->'line_details')=20;
  PERFORM public.test_expect_error(format('SELECT public.submit_inventory_receipt_batch(%L,%L,%s,0,%L,%L::jsonb,%L,%L)',
    po.id,test_uuid(702),po.row_version,'different-request',payload,'Inspector',pth),'INVENTORY_RECEIPT_STALE_VERSION');
  ASSERT (SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501))=10;
  PERFORM set_config('request.jwt.claim.sub',test_uuid(4)::text,true);
  po:=public.verify_inventory_receipt(test_uuid(702),(result->>'row_version')::int,'verify20');
  ASSERT po.status='partially_received';
  ASSERT (SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501))=200;
  RAISE NOTICE 'PASS: twenty-line transaction rollback, zero delivery, file scope, stale version and distinct approvers';
END $batch$;
RESET ROLE;

-- A receipt maker who later becomes an accountant still cannot verify their own work.
INSERT INTO public.inventory_receipts(id,purchase_order_id,restaurant_id,supplier_id,received_by,status)
SELECT test_uuid(703),id,restaurant_id,supplier_id,test_uuid(4),'draft'
FROM public.inventory_purchase_orders WHERE purchase_order_no='history-1';
SET ROLE authenticated;
DO $maker$
BEGIN
  PERFORM set_config('request.jwt.claim.sub',test_uuid(4)::text,true);
  PERFORM public.test_expect_error(format('SELECT public.verify_inventory_receipt(%L,1,%L)',test_uuid(703),'own-receipt'),
    'INVENTORY_RECEIPT_MAKER_CHECKER_REQUIRED');
END $maker$;
RESET ROLE;

-- A manager who edited another maker's draft is also a maker after a role change.
UPDATE public.inventory_receipts SET received_by=test_uuid(1) WHERE id=test_uuid(703);
INSERT INTO public.inventory_receipt_submission_attempts(receipt_id,attempt_key,actor_id,payload_hash,result)
VALUES(test_uuid(703),'historical-manager-submission',test_uuid(4),'fixture-hash','{}');
SET ROLE authenticated;
DO $editor$
BEGIN
  PERFORM set_config('request.jwt.claim.sub',test_uuid(4)::text,true);
  PERFORM public.test_expect_error(format('SELECT public.verify_inventory_receipt(%L,1,%L)',test_uuid(703),'edited-receipt'),
    'INVENTORY_RECEIPT_MAKER_CHECKER_REQUIRED');
END $editor$;
RESET ROLE;
