BEGIN;
INSERT INTO storage.objects(bucket_id,name,metadata,owner_id) VALUES
('inventory-receipt-statements',test_uuid(101)||'/'||test_uuid(8701)||'/receipt.pdf','{"mimetype":"application/pdf","size":120}',test_uuid(1)::text);
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
DO $probe$
DECLARE po public.inventory_purchase_orders%rowtype; detail jsonb; result jsonb; payload jsonb;
BEGIN
 po:=public.create_manual_inventory_purchase_order(test_uuid(101),test_uuid(201),
 jsonb_build_array(jsonb_build_object('supplier_item_id',test_uuid(401),'ordered_quantity_unit',1),
 jsonb_build_object('supplier_item_id',test_uuid(403),'ordered_quantity_unit',0.01)),current_date,NULL);
 po:=public.submit_inventory_purchase_order(po.id,po.row_version);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
 po:=public.store_decide_inventory_purchase_order(po.id,po.row_version,true,NULL);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(3)::text,true);
 po:=public.brand_decide_inventory_purchase_order(po.id,po.row_version,true,NULL);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 detail:=public.get_inventory_workflow_detail(po.id);
 SELECT jsonb_agg(jsonb_build_object('purchase_order_line_id',l->>'id',
 'received_quantity_base',CASE WHEN l->>'supplier_item_id'=test_uuid(401)::text THEN 20 ELSE 0 END,
 'discrepancy_reason','Extra first item; second missing')) INTO payload FROM jsonb_array_elements(detail->'lines') l;
 result:=public.submit_inventory_receipt_batch(po.id,test_uuid(8701),po.row_version,0,'line-balance',payload,'Inspector',
 test_uuid(101)||'/'||test_uuid(8701)||'/receipt.pdf');
 PERFORM set_config('request.jwt.claim.sub',test_uuid(4)::text,true);
 po:=public.verify_inventory_receipt(test_uuid(8701),(result->>'row_version')::int,'verify-line-balance');
 ASSERT po.status='partially_received','A overdelivery must not close missing B';
 RAISE NOTICE 'PASS: receiving completion is per line';
END $probe$;
ROLLBACK;

BEGIN;
DO $tests$
DECLARE po public.inventory_purchase_orders%rowtype; result jsonb; payload jsonb; detail jsonb;
 before_stock numeric; amount numeric; receipt_id uuid:=test_uuid(8702); path text;
BEGIN
 UPDATE public.inventory_supplier_items SET tax_rate=8,order_unit_quantity_base=10 WHERE id=test_uuid(401);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 po:=public.create_manual_inventory_purchase_order(test_uuid(101),test_uuid(201),
   jsonb_build_array(jsonb_build_object('supplier_item_id',test_uuid(401),'ordered_quantity_unit',1)),current_date,NULL);
 po:=public.submit_inventory_purchase_order(po.id,po.row_version);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
 po:=public.store_decide_inventory_purchase_order(po.id,po.row_version,true,NULL);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(3)::text,true);
 po:=public.brand_decide_inventory_purchase_order(po.id,po.row_version,true,NULL);
 UPDATE public.inventory_supplier_items SET tax_rate=20,order_unit_quantity_base=100 WHERE id=test_uuid(401);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 detail:=public.get_inventory_workflow_detail(po.id);
 payload:=jsonb_build_array(jsonb_build_object('purchase_order_line_id',detail->'lines'->0->>'id','received_quantity_base',10));
 path:=test_uuid(101)||'/'||receipt_id||'/receipt.pdf';
 INSERT INTO storage.objects(bucket_id,name,metadata,owner_id) VALUES
 ('inventory-receipt-statements',path,'{"mimetype":"application/pdf","size":120}',test_uuid(1)::text);
 result:=public.submit_inventory_receipt_batch(po.id,receipt_id,po.row_version,0,'terms-capture',payload,'Inspector',path);
 SELECT current_stock INTO before_stock FROM public.inventory_items WHERE id=test_uuid(501);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(4)::text,true);
 po:=public.verify_inventory_receipt(receipt_id,(result->>'row_version')::int,'terms-verify');
 SELECT total_amount INTO amount FROM public.inventory_receipts WHERE id=receipt_id;
 ASSERT amount=108,'Receipt must use 10 units/box and 8% VAT captured at ordering';
 ASSERT po.status='received';
 ASSERT (SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501))=before_stock+10;
 PERFORM public.verify_inventory_receipt(receipt_id,(result->>'row_version')::int,'terms-verify');
 ASSERT (SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501))=before_stock+10;
 PERFORM public.test_expect_error(format('SELECT public.verify_inventory_receipt(%L,%s,%L,%L::jsonb,%L)',
 receipt_id,(result->>'row_version')::int,'terms-verify','[]','Changed payload'),'INVENTORY_RECEIPT_RETRY_MISMATCH');
 ASSERT public.get_inventory_actual_purchase_prices(test_uuid(101))->0 IS NOT NULL;
 RAISE NOTICE 'PASS: immutable conversion/VAT, same-key replay, changed payload rejection, actual price history';
END $tests$;
ROLLBACK;

BEGIN;
DO $mapping$
DECLARE po public.inventory_purchase_orders%rowtype; result jsonb; payload jsonb; detail jsonb;
 receipt_id uuid:=test_uuid(8703); path text;
BEGIN
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 po:=public.create_manual_inventory_purchase_order(test_uuid(101),test_uuid(201),
   jsonb_build_array(jsonb_build_object('supplier_item_id',test_uuid(401),'ordered_quantity_unit',1)),current_date,NULL);
 po:=public.submit_inventory_purchase_order(po.id,po.row_version);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
 po:=public.store_decide_inventory_purchase_order(po.id,po.row_version,true,NULL);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(3)::text,true);
 po:=public.brand_decide_inventory_purchase_order(po.id,po.row_version,true,NULL);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(1)::text,true);
 detail:=public.get_inventory_workflow_detail(po.id);
 payload:=jsonb_build_array(jsonb_build_object('purchase_order_line_id',detail->'lines'->0->>'id','received_quantity_base',10));
 path:=test_uuid(101)||'/'||receipt_id||'/receipt.pdf';
 INSERT INTO storage.objects(bucket_id,name,metadata,owner_id) VALUES
 ('inventory-receipt-statements',path,'{"mimetype":"application/pdf","size":120}',test_uuid(1)::text);
 result:=public.submit_inventory_receipt_batch(po.id,receipt_id,po.row_version,0,'mapping-capture',payload,'Inspector',path);
 UPDATE public.inventory_products SET inventory_item_id=NULL WHERE id=test_uuid(301);
 PERFORM set_config('request.jwt.claim.sub',test_uuid(4)::text,true);
 PERFORM public.test_expect_error(format('SELECT public.verify_inventory_receipt(%L,%s,%L)',
 receipt_id,(result->>'row_version')::int,'mapping-verify'),'INVENTORY_RECEIPT_STOCK_MAPPING_REQUIRED');
 ASSERT (SELECT status FROM public.inventory_receipts WHERE id=receipt_id)='draft';
 ASSERT NOT EXISTS(SELECT 1 FROM public.inventory_transactions WHERE reference_id=receipt_id);
 RAISE NOTICE 'PASS: missing stock mapping fails atomically';
END $mapping$;
ROLLBACK;
