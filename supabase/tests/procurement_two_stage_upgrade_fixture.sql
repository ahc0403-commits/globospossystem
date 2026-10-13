-- An issued/approved legacy request must keep its original approval hash.
CREATE TABLE public.test_procurement_two_stage_upgrade(request_id uuid,approval_hash text,purchase_order_id uuid,snapshot jsonb);
INSERT INTO public.inventory_purchase_requests(id,restaurant_id,source,requested_delivery_date,reason,created_actor,status)
VALUES(test_uuid(13990),test_uuid(101),'pos',current_date,'Legacy approved evidence','{}','approved');
INSERT INTO public.inventory_purchase_request_lines(request_id,product_id,requested_quantity,requested_unit,quantity_base,conversion_snapshot)
VALUES(test_uuid(13990),test_uuid(301),10,'g',10,1);
UPDATE public.inventory_purchase_requests SET approval_hash=public.procurement_request_hash(id) WHERE id=test_uuid(13990);
INSERT INTO public.test_procurement_two_stage_upgrade(request_id,approval_hash) SELECT id,approval_hash FROM public.inventory_purchase_requests WHERE id=test_uuid(13990);
SELECT set_config('app.procurement_write','true',false);
INSERT INTO public.inventory_purchase_orders(id,restaurant_id,supplier_id,purchase_order_no,status,workflow_version,procurement_status,commercial_terms)
VALUES(test_uuid(13991),test_uuid(101),test_uuid(201),'LEGACY-HASH-PRESERVATION','ordered',2,'confirmed','{"approval_policy_version":1}');
INSERT INTO public.inventory_purchase_order_lines(purchase_order_id,product_id,supplier_item_id,ordered_quantity_base,ordered_quantity_unit,order_unit,unit_price,supply_amount,tax_amount,recommendation_snapshot)
VALUES(test_uuid(13991),test_uuid(301),test_uuid(401),10,10,'g',100,1000,0,'{"tax_rate":0,"order_unit_quantity_base":1}');
UPDATE public.test_procurement_two_stage_upgrade SET purchase_order_id=test_uuid(13991),snapshot=public.procurement_snapshots_data(ARRAY[test_uuid(101)],ARRAY[test_uuid(13991)])->0;
