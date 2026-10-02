INSERT INTO brands VALUES(test_uuid(901)),(test_uuid(902));
INSERT INTO restaurants(id,brand_id,name) VALUES(test_uuid(101),test_uuid(901),'A'),(test_uuid(102),test_uuid(902),'B');
INSERT INTO auth.users VALUES(test_uuid(1)),(test_uuid(2));
INSERT INTO users(id,auth_id,role,restaurant_id,primary_store_id) VALUES
(test_uuid(1),test_uuid(1),'store_admin',test_uuid(101),test_uuid(101)),
(test_uuid(2),test_uuid(2),'inventory_orderer',test_uuid(101),test_uuid(101));
INSERT INTO inventory_suppliers(id,supplier_name) VALUES(test_uuid(201),'Supplier');
INSERT INTO inventory_items(id,restaurant_id,name,unit,quantity,current_stock,reorder_point) VALUES
(test_uuid(501),test_uuid(101),'Oil','ml',25000,24770,0),
(test_uuid(502),test_uuid(102),'Other','ea',20,19,5);
INSERT INTO inventory_products(id,restaurant_id,brand_id,name,inventory_item_id,stock_unit,base_unit,base_unit_factor) VALUES
(test_uuid(301),test_uuid(101),test_uuid(901),'Oil',test_uuid(501),'can','ml',25000),
(test_uuid(302),test_uuid(102),test_uuid(902),'Other',test_uuid(502),'bag','ea',5);
INSERT INTO inventory_supplier_items(id,supplier_id,product_id,order_unit,order_unit_quantity_base,min_order_quantity,unit_price,tax_rate,lead_time_days,is_preferred) VALUES
(test_uuid(401),test_uuid(201),test_uuid(301),'can',25000,2,320000,8,3,true);
SET request.jwt.claim.sub='00000000-0000-4000-8000-000000000001';
SET request.jwt.claim.role='authenticated';
DO $$ DECLARE result jsonb; invalid numeric; BEGIN
 result:=upsert_inventory_product_with_supplier_v2(test_uuid(101),test_uuid(201),test_uuid(301),p_name:='Oil',p_stock_unit:='can',p_base_unit:='ml',p_base_unit_factor:=25000,p_safety_stock_base:=5000);
 ASSERT result->>'safety_stock_base'='5000.000';
 ASSERT (SELECT current_stock=24770 AND quantity=25000 AND reorder_point=5000 FROM inventory_items WHERE id=test_uuid(501));
 ASSERT (SELECT unit_price=320000 AND tax_rate=8 AND min_order_quantity=2 AND lead_time_days=3 AND order_unit_quantity_base=25000 FROM inventory_supplier_items WHERE id=test_uuid(401));
 ASSERT (SELECT current_stock=19 AND reorder_point=5 FROM inventory_items WHERE id=test_uuid(502));
 ASSERT (SELECT count(*) FROM inventory_transactions)=0;
 ASSERT (SELECT count(*) FROM audit_logs WHERE action='inventory_safety_stock_updated')=1;
 PERFORM upsert_inventory_product_with_supplier_v2(test_uuid(101),test_uuid(201),test_uuid(301),p_name:='Oil',p_stock_unit:='can',p_base_unit:='ml',p_base_unit_factor:=25000,p_safety_stock_base:=NULL);
 ASSERT (SELECT reorder_point IS NULL FROM inventory_items WHERE id=test_uuid(501));
 PERFORM upsert_inventory_product_with_supplier_v2(test_uuid(101),test_uuid(201),test_uuid(301),p_name:='Oil',p_stock_unit:='can',p_base_unit:='ml',p_base_unit_factor:=25000,p_safety_stock_base:=0);
 ASSERT (SELECT reorder_point=0 FROM inventory_items WHERE id=test_uuid(501));
 FOREACH invalid IN ARRAY ARRAY[-1::numeric,0.00001::numeric,'NaN'::numeric,'Infinity'::numeric,1000000000::numeric] LOOP
  BEGIN
   PERFORM upsert_inventory_product_with_supplier_v2(test_uuid(101),test_uuid(201),test_uuid(301),p_name:='Must not save',p_stock_unit:='can',p_safety_stock_base:=invalid);
   RAISE EXCEPTION 'INVALID_ACCEPTED';
  EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='INVENTORY_SAFETY_STOCK_INVALID',SQLERRM; END;
 END LOOP;
 ASSERT (SELECT name='Oil' AND reorder_point=0 FROM inventory_items WHERE id=test_uuid(501));
 BEGIN
  PERFORM upsert_inventory_product_with_supplier_v2(test_uuid(101),test_uuid(999),test_uuid(301),p_name:='Rollback this',p_stock_unit:='can',p_safety_stock_base:=6000);
  RAISE EXCEPTION 'INVALID_SUPPLIER_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='SUPPLIER_NOT_FOUND',SQLERRM; END;
 ASSERT (SELECT name='Oil' AND reorder_point=0 FROM inventory_items WHERE id=test_uuid(501));
 BEGIN
  PERFORM upsert_inventory_product_with_supplier_v2(test_uuid(102),test_uuid(201),test_uuid(302),p_name:='Forbidden',p_stock_unit:='bag',p_base_unit:='ea',p_base_unit_factor:=5,p_safety_stock_base:=10);
  RAISE EXCEPTION 'OTHER_STORE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='INVENTORY_PRODUCT_FORBIDDEN',SQLERRM; END;
 result:=upsert_inventory_product_with_supplier_v2(test_uuid(101),test_uuid(201),p_name:='New bag item',p_stock_unit:='bag',p_base_unit:='ea',p_base_unit_factor:=5,p_safety_stock_base:=4);
 ASSERT (SELECT reorder_point=4 AND quantity=0 AND current_stock=0 FROM inventory_items WHERE id=(result->'product'->>'inventory_item_id')::uuid);
 PERFORM upsert_inventory_product_with_supplier_v2(test_uuid(101),test_uuid(201),test_uuid(301),p_name:='Oil',p_stock_unit:='can',p_base_unit:='ml',p_base_unit_factor:=25000,p_safety_stock_base:=5000);
 -- A pre-v2 client editing the same product must preserve the new threshold.
 PERFORM upsert_inventory_product_with_supplier(test_uuid(101),test_uuid(201),test_uuid(301),p_name:='Oil',p_stock_unit:='can',p_base_unit:='ml',p_base_unit_factor:=25000);
 ASSERT (SELECT reorder_point=5000 AND quantity=25000 AND current_stock=24770 FROM inventory_items WHERE id=test_uuid(501));
END $$;
SET request.jwt.claim.sub='00000000-0000-4000-8000-000000000002';
DO $$ BEGIN
 BEGIN
  PERFORM upsert_inventory_product_with_supplier_v2(test_uuid(101),test_uuid(201),test_uuid(301),p_name:='Forbidden',p_stock_unit:='can',p_safety_stock_base:=5);
  RAISE EXCEPTION 'ORDERER_WRITE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='INVENTORY_PRODUCT_FORBIDDEN',SQLERRM; END;
END $$;
SET request.jwt.claim.sub='';
DO $$ BEGIN
 BEGIN
  PERFORM upsert_inventory_product_with_supplier_v2(test_uuid(101),test_uuid(201),test_uuid(301),p_safety_stock_base:=5);
  RAISE EXCEPTION 'UNAUTHENTICATED_WRITE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='AUTHENTICATION_REQUIRED',SQLERRM; END;
END $$;
SELECT 'Safety stock values, stock preservation, atomicity and store permissions: PASS';
SET request.jwt.claim.sub='00000000-0000-4000-8000-000000000001';
INSERT INTO inventory_items(id,restaurant_id,name,unit,quantity,current_stock) VALUES(test_uuid(503),test_uuid(101),'Legacy bag','ea',20,18);
INSERT INTO inventory_products(id,restaurant_id,name,inventory_item_id,stock_unit,base_unit,base_unit_factor) VALUES(test_uuid(303),test_uuid(101),'Legacy bag',test_uuid(503),'bag','ea',5);
DO $$ BEGIN
 PERFORM set_inventory_product_safety_stock(test_uuid(101),test_uuid(303),4,'ea');
 ASSERT (SELECT reorder_point=4 AND quantity=20 AND current_stock=18 FROM inventory_items WHERE id=test_uuid(503));
 ASSERT NOT EXISTS(SELECT 1 FROM inventory_supplier_items WHERE product_id=test_uuid(303));
 ASSERT (SELECT shelf_life_days IS NULL FROM inventory_products WHERE id=test_uuid(303));
 PERFORM set_inventory_product_safety_stock(test_uuid(101),test_uuid(303),NULL,'ea');
 ASSERT (SELECT reorder_point IS NULL FROM inventory_items WHERE id=test_uuid(503));
 PERFORM set_inventory_product_safety_stock(test_uuid(101),test_uuid(303),0,'ea');
 ASSERT (SELECT reorder_point=0 FROM inventory_items WHERE id=test_uuid(503));
 BEGIN
  PERFORM set_inventory_product_safety_stock(test_uuid(101),test_uuid(303),1000,'g');
  RAISE EXCEPTION 'STALE_UNIT_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='INVENTORY_SAFETY_STOCK_UNIT_CHANGED',SQLERRM; END;
 BEGIN
  PERFORM set_inventory_product_safety_stock(test_uuid(102),test_uuid(302),4,'ea');
  RAISE EXCEPTION 'OTHER_STORE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='INVENTORY_PRODUCT_FORBIDDEN',SQLERRM; END;
 ASSERT (SELECT reorder_point=0 AND quantity=20 AND current_stock=18 FROM inventory_items WHERE id=test_uuid(503));
 ASSERT (SELECT count(*) FROM inventory_transactions)=0;
END $$;
SELECT 'Legacy products, unset/zero and stale unit protection: PASS';
SET request.jwt.claim.sub='00000000-0000-4000-8000-000000000002';
DO $$ BEGIN
 BEGIN
  PERFORM set_inventory_product_safety_stock(test_uuid(101),test_uuid(303),4,'ea');
  RAISE EXCEPTION 'OPERATOR_THRESHOLD_WRITE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='INVENTORY_PRODUCT_FORBIDDEN',SQLERRM; END;
END $$;
SET request.jwt.claim.sub='';
DO $$ BEGIN
 BEGIN
  PERFORM set_inventory_product_safety_stock(test_uuid(101),test_uuid(303),4,'ea');
  RAISE EXCEPTION 'ANONYMOUS_THRESHOLD_WRITE_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='AUTHENTICATION_REQUIRED',SQLERRM; END;
END $$;
