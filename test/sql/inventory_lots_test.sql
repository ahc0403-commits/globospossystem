BEGIN;
CREATE SCHEMA IF NOT EXISTS storage;
CREATE TABLE IF NOT EXISTS storage.objects(id uuid DEFAULT gen_random_uuid() PRIMARY KEY,bucket_id text,name text,owner_id text,metadata jsonb);
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS is_sso_user boolean NOT NULL DEFAULT false;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
UPDATE brands SET short_code='LAB' WHERE id='91000000-0000-4000-8000-000000000003';
DO $$ DECLARE
 loc uuid:=gen_random_uuid(); holdloc uuid:=gen_random_uuid(); rejectloc uuid:=gen_random_uuid(); count_id uuid:=gen_random_uuid(); held_id uuid; disposition_id uuid:=gen_random_uuid(); release_id uuid:=gen_random_uuid(); release_payload jsonb; frozen_report jsonb; count_payload jsonb; quality uuid:=gen_random_uuid(); next_quality uuid:=gen_random_uuid(); employee store_employees; criteria jsonb; request uuid:=gen_random_uuid(); shop uuid; lease jsonb; template uuid:=gen_random_uuid(); family uuid:=gen_random_uuid(); spec uuid:=gen_random_uuid(); approval uuid:=gen_random_uuid();
 brand uuid:='91000000-0000-4000-8000-000000000003'; entity uuid:='91000000-0000-4000-8000-000000000004';
 item uuid; product uuid; supplier uuid; supplier_item uuid; comparison_supplier uuid; comparison_item uuid; ready jsonb; r jsonb; payload jsonb; requester uuid; manager uuid; buyer_id uuid:=gen_random_uuid(); buyer jsonb; rid uuid; line uuid; quote uuid; po uuid; po_line uuid; receipt uuid:=gen_random_uuid(); path text; stock numeric; food uuid; sale uuid; sale_line uuid; total numeric; receipt_price numeric:=coalesce(nullif(current_setting('test.held_price',true),''),'100')::numeric;
BEGIN
 shop:=admin_register_store_v1(request,jsonb_build_object('name','Single hall procurement','brand',brand,'entity',entity));
 lease:=claim_store_onboarding_v1(request);
 INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at,raw_app_meta_data)
 SELECT gen_random_uuid(),a->>'account_code'||'@globos.world','00000000-0000-0000-0000-000000000000','authenticated','authenticated',now(),
 jsonb_build_object('store_onboarding',jsonb_build_object('code',a->>'account_code','role',a->>'role','type',a->>'account_type','scope',a->>'scope','owner_id',a->>'owner_id'))
 FROM jsonb_array_elements(lease->'items')a WHERE NOT (a->>'auth_exists')::boolean;
 PERFORM finish_store_onboarding_v1(request,(lease->>'lease_id')::uuid);
 ready:=admin_get_procurement_setup_v1(shop);
 ASSERT ready->'readiness'->>'ready'='false';
 PERFORM admin_publish_procurement_template_v1(template,family,0,'Fixture approved policy','{"stock_freshness_hours":24}');
 PERFORM admin_apply_procurement_template_v1(shop,template,0);
 PERFORM admin_apply_procurement_template_v1(shop,template,0);
 ASSERT (SELECT revision=1 FROM store_procurement_profiles WHERE restaurant_id=shop);
 BEGIN PERFORM admin_publish_procurement_template_v1(gen_random_uuid(),family,0,'Conflict','{"stock_freshness_hours":24}'); RAISE EXCEPTION 'stale policy accepted'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='PROCUREMENT_TEMPLATE_STALE',SQLERRM; END;
 INSERT INTO inventory_items(restaurant_id,name,unit,current_stock) VALUES(shop,'Fixture raw','g',0) RETURNING id INTO item;
 INSERT INTO inventory_products(restaurant_id,brand_id,inventory_item_id,product_code,name,stock_unit,base_unit,base_unit_factor,specification) VALUES(shop,brand,item,'RAW-01','Fixture raw','g','g',1,'Approved source specification') RETURNING id INTO product;
 INSERT INTO inventory_suppliers(brand_id,supplier_name) VALUES(brand,'Fixture supplier') RETURNING id INTO supplier;
 INSERT INTO inventory_supplier_items(supplier_id,product_id,supplier_sku,order_unit,order_unit_quantity_base,min_order_quantity,unit_price) VALUES(supplier,product,'SKU-01','g',1,1,100) RETURNING id INTO supplier_item;
 PERFORM admin_publish_material_spec_v1(spec,'RAW-01',0,'Fixture raw','g','Approved source specification');
 payload:=jsonb_build_array(jsonb_build_object('id',approval,'product_id',product,'supplier_item_id',supplier_item,'spec_id',spec,'valid_from',now()-interval '1 day','source_reference','Supplier specification and quote fixture'));
 PERFORM admin_approve_procurement_catalog_v1(shop,payload);
 PERFORM admin_approve_procurement_catalog_v1(shop,payload);
 ASSERT (SELECT count(*)=1 FROM procurement_catalog_approvals WHERE id=approval);
 ready:=admin_get_procurement_setup_v1(shop);
 ASSERT ready->'readiness'->'checks'->>'catalog'='true',ready::text;
 ASSERT ready->'readiness'->'checks'->>'buyer'='false',ready::text;
 INSERT INTO procurement_role_roster(restaurant_id,system,subject_id,stage,display_name,valid_from,valid_until,reason,assigned_by,account_kind)
 SELECT shop,'office',buyer_id,s,'Fixture Office principal',now()-interval '1 day',now()+interval '1 day','Isolated native-scope fixture','{"system":"office_scope_sync"}','shared_role' FROM unnest(ARRAY['purchase','finance'])s;
 UPDATE procurement_store_onboarding SET office_connected=true WHERE restaurant_id=shop;
 criteria:='{"temperature_required":true,"temperature_min_c":0,"temperature_max_c":5,"expiry_required":true,"min_remaining_days":7,"min_sample_count":2,"photo_required":false,"lot_required":true}';
 PERFORM admin_publish_quality_profile_v1(quality,shop,product,0,criteria,'Approved isolated test criteria');
 employee:=create_store_employee(shop,'Fixture actual receiver','manager');
 PERFORM admin_save_inventory_location_v1(loc,shop,'Shelf','storage',true,0);
 PERFORM admin_save_inventory_location_v1(holdloc,shop,'Inspection hold','quarantine',true,0);
 PERFORM admin_save_inventory_location_v1(rejectloc,shop,'Rejected','rejected',true,0);
 count_payload:=jsonb_build_array(jsonb_build_object('product_id',product,'inventory_item_id',item,'unit','g','expected_stock',0,'actual_quantity_base',0,'unit_cost_base',100,'cost_source','Approved fixture quote','counted_at',clock_timestamp(),'track_lots',true,'lots','[]'::jsonb));
 PERFORM admin_record_inventory_lot_count_v1(count_id,shop,employee.id,count_payload,'Explicit opening physical count');
 PERFORM admin_record_inventory_lot_count_v1(count_id,shop,employee.id,count_payload,'Explicit opening physical count');
 ASSERT (SELECT count(*)=1 FROM inventory_transactions WHERE reference_id=count_id);

 ready:=admin_get_procurement_setup_v1(shop);
 ASSERT ready->'readiness'->>'ready'='true',ready::text;
 ASSERT (SELECT state='preparing' FROM store_lifecycle WHERE restaurant_id=shop),'buying incorrectly opens sales';
 UPDATE inventory_supplier_items SET order_unit_quantity_base=1000 WHERE id=supplier_item;
 ASSERT admin_get_procurement_setup_v1(shop)->'readiness'->'checks'->>'catalog'='false','changed conversion retained approval';
 UPDATE inventory_supplier_items SET order_unit_quantity_base=1 WHERE id=supplier_item;
 UPDATE procurement_role_roster SET valid_until=now()-interval '1 hour' WHERE restaurant_id=shop AND system='office';
 ASSERT admin_get_procurement_setup_v1(shop)->'readiness'->>'ready'='false','expired buyer accepted';
 UPDATE procurement_role_roster SET valid_until=now()+interval '1 day' WHERE restaurant_id=shop AND system='office';
 SELECT auth_id INTO requester FROM users WHERE restaurant_id=shop AND fixed_account_code LIKE '%\_pr1';
 SELECT auth_id INTO manager FROM users WHERE restaurant_id=shop AND role='store_admin';
 buyer:=jsonb_build_object('system','office','subject_id',buyer_id,'store_id',shop,'can_manage',true,'can_create',true,'can_office_approve',true,'can_view_prices',true);
 PERFORM set_config('request.jwt.claim.role','authenticated',true); PERFORM set_config('request.jwt.claim.sub',requester::text,true);
 payload:=jsonb_build_object('reason','First single-hall stock','requested_delivery_date',current_date+2,'lines',jsonb_build_array(jsonb_build_object('product_id',product,'quantity',10,'unit','g')));
 r:=procurement_command(shop,'create_request',NULL,0,'first-request',payload); rid:=(r->>'id')::uuid;
 ASSERT r->>'approval_policy_version'='3';
 SELECT id INTO line FROM inventory_purchase_request_lines WHERE request_id=rid AND active;
 r:=procurement_command(shop,'submit_request',rid,1,'first-submit');
 PERFORM set_config('request.jwt.claim.sub',manager::text,true);
 r:=procurement_command(shop,'store_approve',rid,2,'first-store'); ASSERT r->>'status'='office_review';
 PERFORM set_config('request.jwt.claim.role','service_role',true);
 r:=procurement_command(shop,'save_quote',rid,3,'first-quote',jsonb_build_object('supplier_id',supplier,'valid_until',current_date+2,'delivery_date',current_date+2,'payment_terms','Net 7','evidence_reference','Written quote','lines',jsonb_build_array(jsonb_build_object('request_line_id',line,'supplier_item_id',supplier_item,'quantity_base',10,'unit_price',100,'tax_rate',0))),buyer);
 SELECT id INTO quote FROM procurement_quotes WHERE request_id=rid;
 -- The first purchase has no price history, so retain the existing two-quote rule.
 INSERT INTO inventory_suppliers(brand_id,supplier_name) VALUES(brand,'Comparison supplier') RETURNING id INTO comparison_supplier;
 INSERT INTO inventory_supplier_items(supplier_id,product_id,order_unit,order_unit_quantity_base,min_order_quantity,unit_price) VALUES(comparison_supplier,product,'g',1,1,110) RETURNING id INTO comparison_item;
 r:=procurement_command(shop,'save_quote',rid,4,'comparison-quote',jsonb_build_object('supplier_id',comparison_supplier,'valid_until',current_date+2,'delivery_date',current_date+2,'payment_terms','Net 7','evidence_reference','Comparison quote','lines',jsonb_build_array(jsonb_build_object('request_line_id',line,'supplier_item_id',comparison_item,'quantity_base',10,'unit_price',110,'tax_rate',0))),buyer);
 r:=procurement_command(shop,'select_quote',rid,5,'first-select',jsonb_build_object('quote_id',quote,'reason','Selected'),buyer);
 r:=procurement_command(shop,'office_approve',rid,6,'first-approve','{}',buyer); ASSERT r->>'status'='approved';
 r:=procurement_command(shop,'issue_po',rid,7,'first-issue',jsonb_build_object('quote_id',quote,'delivery_address','Store','contact_name','Receiver'),buyer);
 po:=(r->'purchase_order'->>'id')::uuid; ASSERT po IS NOT NULL;
 PERFORM set_config('app.procurement_write','true',true);
 UPDATE inventory_purchase_orders SET procurement_status='confirmed' WHERE id=po;
 SELECT id INTO po_line FROM inventory_purchase_order_lines WHERE purchase_order_id=po;
 PERFORM set_config('request.jwt.claim.role','authenticated',true); PERFORM set_config('request.jwt.claim.sub',requester::text,true);
 path:=shop::text||'/'||receipt::text||'/statement.pdf';
 INSERT INTO storage.objects(bucket_id,name,owner_id,metadata) VALUES('inventory-receipt-statements',path,requester::text,'{"mimetype":"application/pdf","size":100}');
 SELECT current_stock INTO stock FROM inventory_items WHERE id=item;
 SELECT to_jsonb(o) INTO r FROM inventory_purchase_orders o WHERE id=po;
 payload:=jsonb_build_object('p_purchase_order_id',po,'p_receipt_id',receipt,'p_expected_order_version',r->'row_version','p_expected_receipt_version',0,'p_idempotency_key','first-receive','p_inspector_name','Fixture actual receiver','p_statement_storage_path',path,
 'p_lines',jsonb_build_array(jsonb_build_object('purchase_order_line_id',po_line,'received_quantity_base',10,'inspection',jsonb_build_object('spec_ok',true,'quality_ok',true,'packaging_ok',true,'expiry_not_applicable',false,'expiry_date',current_date+8,'temperature_c',3,'temperature_ok',true,'quality_profile_id',quality,'sample_count',2,'employee_id',employee.id,'issue_type','none','photo_paths','[]'::jsonb))));

 payload:=jsonb_set(payload,'{p_lines,0,held_quantity_base}','3');
 payload:=jsonb_set(payload,'{p_lines,0,rejected_quantity_base}','1');
 payload:=jsonb_set(payload,'{p_lines,0,discrepancy_reason}','"Inspect held batch before use"');
 payload:=jsonb_set(payload,'{p_lines,0,inspection,issue_type}','"quality"');
 BEGIN PERFORM finalize_procurement_receipt(payload); RAISE EXCEPTION 'lots omitted'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='INVENTORY_RECEIPT_LOTS_REQUIRED',SQLERRM; END;
 payload:=jsonb_set(payload,'{p_lines,0,inspection,lots}',jsonb_build_array(
 jsonb_build_object('code','BATCH-A','expiry_date',current_date+8,'accepted',4,'held',3,'rejected',1,'location_id',loc,'held_location_id',holdloc,'rejected_location_id',rejectloc),
 jsonb_build_object('code','BATCH-B','expiry_date',current_date+20,'accepted',2,'held',0,'rejected',0,'location_id',loc)));
 IF receipt_price<>100 THEN
  PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
  UPDATE storage.objects SET owner_id='92000000-0000-4000-8000-000000000099' WHERE name=path;
  payload:=jsonb_set(payload,'{p_lines,0,actual_unit_price}',to_jsonb(receipt_price));
 END IF;
 r:=finalize_procurement_receipt(payload);
 ASSERT r->>'status'='confirmed',r::text;
 ASSERT (SELECT current_stock=6 FROM inventory_items WHERE id=item);
 ASSERT (SELECT sum(quantity_base)=6 FROM inventory_lots WHERE ingredient_id=item AND state='available');
 ASSERT (SELECT sum(quantity_base)=3 FROM inventory_lots WHERE ingredient_id=item AND state='held');
 ASSERT (SELECT sum(quantity_base)=1 FROM inventory_lots WHERE ingredient_id=item AND state='rejected');
 PERFORM finalize_procurement_receipt(payload);
 ASSERT (SELECT current_stock=6 FROM inventory_items WHERE id=item),'retry duplicated stock';
 ASSERT (SELECT held_quantity_base=3 AND accepted_quantity_base=6 AND rejected_quantity_base=1 FROM inventory_receipt_lines WHERE receipt_id=receipt);
 PERFORM set_config('request.jwt.claim.sub',requester::text,true);
 SELECT id INTO held_id FROM inventory_lots WHERE ingredient_id=item AND state='held';
 SELECT data INTO frozen_report FROM procurement_receipt_reports WHERE receipt_id=receipt;
 INSERT INTO storage.objects(bucket_id,name,owner_id,metadata) VALUES('inventory-receipt-statements',shop::text||'/'||release_id::text||'/release.jpg',requester::text,'{"mimetype":"image/jpeg","size":100}');
 release_payload:=jsonb_build_object('employee_id',employee.id,'reason','Inspected held units meet criteria','evidence_reference','Fixture reinspection statement','receipt_id',release_id,'location_id',loc,'expected_order_version',(SELECT row_version FROM inventory_purchase_orders WHERE id=po),'statement_storage_path',shop::text||'/'||release_id::text||'/release.jpg','inspection',payload->'p_lines'->0->'inspection');
 r:=inventory_dispose_lot_v1(disposition_id,shop,held_id,'release',2,release_payload);
 PERFORM inventory_dispose_lot_v1(disposition_id,shop,held_id,'release',2,release_payload);
 ASSERT (SELECT actual_unit_price=receipt_price FROM inventory_receipt_lines WHERE receipt_id=release_id AND accepted_quantity_base>0),'released price differs from original receipt';
 ASSERT (SELECT current_stock=8 FROM inventory_items WHERE id=item),'hold release stock or retry incorrect';
 ASSERT (SELECT sum(quantity_base)=1 FROM inventory_lots WHERE ingredient_id=item AND state='held');
 ASSERT (SELECT sum(accepted_quantity_base)=8 FROM inventory_receipt_lines WHERE purchase_order_line_id=po_line);
 ASSERT (SELECT data=frozen_report FROM procurement_receipt_reports WHERE receipt_id=receipt),'original report changed';
 ASSERT (SELECT data->>'receipt_origin'='hold_release' FROM procurement_receipt_reports WHERE receipt_id=release_id);
 r:=inventory_dispose_lot_v1(gen_random_uuid(),shop,held_id,'return',1,jsonb_build_object('employee_id',employee.id,'reason','Return remaining held sample','evidence_reference','Fixture supplier return handoff'));
 ASSERT (SELECT current_stock=8 FROM inventory_items WHERE id=item),'held return deducted available stock';
 SET CONSTRAINTS ALL IMMEDIATE;
 SET CONSTRAINTS ALL DEFERRED;
 -- A single transaction batch crossing lots allocates FEFO exactly once.
 UPDATE inventory_items SET current_stock=3 WHERE id=item;
 INSERT INTO inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,reference_id)
 VALUES(shop,item,'deduct',-3,'fixture',gen_random_uuid()),(shop,item,'deduct',-2,'fixture_other',gen_random_uuid());
 ASSERT (SELECT sum(quantity_base)=1 FROM inventory_lots WHERE ingredient_id=item AND state='available' AND supplier_lot_code='BATCH-A');
 ASSERT (SELECT quantity_base=2 FROM inventory_lots WHERE ingredient_id=item AND state='available' AND supplier_lot_code='BATCH-B');
 SET CONSTRAINTS ALL IMMEDIATE;
 SET CONSTRAINTS ALL DEFERRED;
 BEGIN
 UPDATE inventory_items SET current_stock=0 WHERE id=item;
 SET CONSTRAINTS ALL IMMEDIATE;
 RAISE EXCEPTION 'unlinked stock accepted';
 EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='INVENTORY_LOT_BALANCE_MISMATCH',SQLERRM; END;
 ASSERT (SELECT current_stock=3 FROM inventory_items WHERE id=item);
 PERFORM set_config('request.jwt.claim.sub',requester::text,true);
 r:=procurement_command(shop,'return_goods',po,(SELECT row_version FROM inventory_purchase_orders WHERE id=po),'return-tracked-'||gen_random_uuid(),jsonb_build_object('receipt_line_id',(SELECT id FROM inventory_receipt_lines WHERE receipt_id=receipt),'quantity_base',1,'reason','Return original accepted lot','evidence_reference','Supplier acknowledged physical return'));
 ASSERT (SELECT current_stock=2 FROM inventory_items WHERE id=item);
 ASSERT (SELECT sum(quantity_base)=2 FROM inventory_lots WHERE ingredient_id=item AND state='available');
 SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED;
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
 UPDATE store_lifecycle SET state='active' WHERE restaurant_id=shop;
 PERFORM approve_invoice_mapping_policy(shop,entity,'lot-payment','{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','Tracked sale regression');
 INSERT INTO menu_items(restaurant_id,name,name_vi,invoice_sale_unit,price) VALUES(shop,'Tracked ingredient sale','Món kiểm tra lô','Phần',10000) RETURNING id INTO food;
 INSERT INTO menu_recipes(restaurant_id,menu_item_id,ingredient_id,quantity_g) VALUES(shop,food,item,1);
 INSERT INTO orders(restaurant_id,status) VALUES(shop,'serving') RETURNING id INTO sale;
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,item_type,label,display_name,unit_price,quantity,status) VALUES(shop,sale,food,'menu_item','Tracked sale','Tracked sale',10000,1,'served') RETURNING id INTO sale_line;
 PERFORM process_payment(sale,shop,1,'CASH');
 SELECT sum(paying_amount_inc_tax)-1 INTO total FROM order_items WHERE order_id=sale;
 PERFORM process_payment(sale,shop,total,'BANKTRANSFER');
 ASSERT (SELECT status='completed' FROM orders WHERE id=sale);
 ASSERT (SELECT current_stock=1 FROM inventory_items WHERE id=item),'actual split payment stock differs';
 ASSERT (SELECT sum(quantity_base)=1 FROM inventory_lots WHERE ingredient_id=item AND state='available');
 SET CONSTRAINTS ALL IMMEDIATE; SET CONSTRAINTS ALL DEFERRED;
 -- Expired available stock remains physically counted but cannot serve a sale.
 BEGIN
  UPDATE inventory_lots SET expiry_date=current_date-1 WHERE ingredient_id=item AND state='available';
  UPDATE inventory_items SET current_stock=0 WHERE id=item;
  INSERT INTO inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,reference_id) VALUES(shop,item,'deduct',-1,'order_item',gen_random_uuid());
  RAISE EXCEPTION 'expired lot consumed';
 EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='INVENTORY_AVAILABLE_LOT_SHORTAGE',SQLERRM; END;
 ASSERT (SELECT current_stock=1 FROM inventory_items WHERE id=item);
 DECLARE legacy_item uuid; legacy_product uuid; legacy_rows jsonb; BEGIN
  INSERT INTO inventory_items(restaurant_id,name,unit,current_stock) VALUES(shop,'Existing untraceable stock','g',5) RETURNING id INTO legacy_item;
  INSERT INTO inventory_products(restaurant_id,brand_id,inventory_item_id,product_code,name,stock_unit,base_unit,base_unit_factor,specification) VALUES(shop,brand,legacy_item,'OLD-RAW','Existing stock','g','g',1,'Legacy count') RETURNING id INTO legacy_product;
  PERFORM admin_publish_quality_profile_v1(gen_random_uuid(),shop,legacy_product,0,criteria,'Explicit traceability adoption');
  legacy_rows:=jsonb_build_array(jsonb_build_object('product_id',legacy_product,'inventory_item_id',legacy_item,'unit','g','expected_stock',5,'actual_quantity_base',5,'unit_cost_base',100,'cost_source','Recorded prior cost evidence','counted_at',clock_timestamp(),'track_lots',true,'lots',jsonb_build_array(jsonb_build_object('quantity_base',5,'location_id',loc))));
  BEGIN PERFORM admin_record_inventory_lot_count_v1(gen_random_uuid(),shop,employee.id,legacy_rows,'Legacy stock physical count'); RAISE EXCEPTION 'unknown stock implicitly accepted'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='INVENTORY_COUNT_LOT_INVALID',SQLERRM; END;
  legacy_rows:=jsonb_set(legacy_rows,'{0,acknowledge_unknown_legacy}','true');
  PERFORM admin_record_inventory_lot_count_v1(gen_random_uuid(),shop,employee.id,legacy_rows,'Legacy stock physical count');
  ASSERT (SELECT current_stock=5 FROM inventory_items WHERE id=legacy_item),'carry-forward duplicated stock';
  ASSERT EXISTS(SELECT 1 FROM inventory_lots WHERE ingredient_id=legacy_item AND source_kind='unknown_legacy' AND supplier_lot_code IS NULL AND expiry_date IS NULL AND quantity_base=5);
 END;
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
SELECT 'INVENTORY_LOTS=PASS opening zero, accepted/held/rejected split, retry, FEFO batch, deferred reconciliation';
ROLLBACK;
