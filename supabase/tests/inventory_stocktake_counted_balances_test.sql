SET request.jwt.claim.role='service_role';
DO $$ DECLARE store uuid:=test_uuid(8100); item uuid:=test_uuid(8101); zero_item uuid:=test_uuid(8102); blank_item uuid:=test_uuid(8103);
 pid uuid:=test_uuid(8111); zero_pid uuid:=test_uuid(8112); blank_pid uuid:=test_uuid(8113); s jsonb; lines jsonb; preview jsonb; balances jsonb;
 reference timestamptz:='2026-09-30T23:59:59+07:00';
BEGIN
 INSERT INTO restaurants(id,brand_id,name) VALUES(store,'a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878','Isolated counted balances');
 INSERT INTO inventory_items(id,restaurant_id,name,quantity,current_stock,unit,created_at) VALUES
 (item,store,'Late registered drink',100,100,'ea','2026-10-01T01:00:00+07:00'),
 (zero_item,store,'Explicit zero',30,30,'g','2026-09-01'),
 (blank_item,store,'Uncounted packaging',12,12,'ea','2026-09-01');
 INSERT INTO inventory_products(id,restaurant_id,brand_id,inventory_item_id,product_code,name,stock_unit,base_unit,base_unit_factor) VALUES
 (pid,store,'a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878',item,'DR001','Late registered drink','BOX','ea',24),
 (zero_pid,store,'a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878',zero_item,'WR001','Explicit zero','kg','g',10000),
 (blank_pid,store,'a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878',blank_item,'GO001','Uncounted packaging','ea','ea',1);
 IF inventory_stock_at(item,reference)->>'quantity' IS NOT NULL THEN RAISE EXCEPTION 'PRE_COUNT_HISTORY_INVENTED'; END IF;
 s:=prepare_inventory_stock_audit_v2(store,'2026-09-30',reference);
 SELECT jsonb_agg(jsonb_build_object('product_id',x->>'product_id','actual_quantity_base',CASE WHEN x->>'product_id'=pid::text THEN 80 END,
  'counted_at',reference,'excluded_reason',CASE WHEN x->>'product_id'<>pid::text THEN 'not counted' END)) INTO lines FROM jsonb_array_elements(s->'snapshot') x;
 preview:=preview_inventory_stock_audit_v3(store,(s->>'id')::uuid,lines,true,true);
 PERFORM save_inventory_stock_audit_v3(store,(s->>'id')::uuid,1,lines,true,NULL,preview->>'token',true,true);
 IF (inventory_stock_at(item,reference)->>'quantity')::numeric<>80 OR inventory_stock_at(item,reference)->>'source'<>'counted_anchor'
 OR inventory_stock_at(item,reference-interval '1 second')->>'quantity' IS NOT NULL THEN RAISE EXCEPTION 'INITIAL_COUNT_AVAILABILITY_FAILED'; END IF;
 -- Supplemental counts at the same reference must retain the earlier counted item.
 s:=prepare_inventory_stock_audit_v2(store,'2026-09-30',reference);
 SELECT jsonb_agg(jsonb_build_object('product_id',x->>'product_id','actual_quantity_base',CASE WHEN x->>'product_id'=zero_pid::text THEN 0 END,
  'counted_at',reference,'excluded_reason',CASE WHEN x->>'product_id'<>zero_pid::text THEN 'already counted or blank' END)) INTO lines FROM jsonb_array_elements(s->'snapshot') x;
 preview:=preview_inventory_stock_audit_v3(store,(s->>'id')::uuid,lines,true,true);
 PERFORM save_inventory_stock_audit_v3(store,(s->>'id')::uuid,1,lines,true,NULL,preview->>'token',true,true);
 UPDATE inventory_items SET current_stock=current_stock-10 WHERE id=item;
 INSERT INTO inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,effective_at,created_at) VALUES(store,item,'deduct',-10,'2026-10-01T02:00:00+07:00',clock_timestamp());
 balances:=get_inventory_stock_audit_balances(store,'2026-09-30');
 IF jsonb_array_length(balances->'rows')<>3 OR (balances->>'effective_at')::timestamptz<>reference
 OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(balances->'rows') r WHERE r->>'product_id'=pid::text AND (r->>'system_quantity_base')::numeric=80 AND (r->>'actual_quantity_base')::numeric=80 AND (r->>'variance_quantity_base')::numeric=0)
 OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(balances->'rows') r WHERE r->>'product_id'=zero_pid::text AND (r->>'system_quantity_base')::numeric=0 AND (r->>'actual_quantity_base')::numeric=0)
 OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(balances->'rows') r WHERE r->>'product_id'=blank_pid::text AND (r->>'system_quantity_base')::numeric=12 AND r->>'actual_quantity_base' IS NULL)
 OR (SELECT current_stock FROM inventory_items WHERE id=item)<>70 THEN RAISE EXCEPTION 'DATED_BALANCES_OR_EXCLUSIONS_FAILED %',balances; END IF;
 IF get_inventory_stock_audit_balances(store)->>'business_date'<>'2026-09-30'
 OR (inventory_stock_at(item,'2026-10-01T03:00:00+07:00')->>'quantity')::numeric<>70 THEN RAISE EXCEPTION 'DEFAULT_DATE_OR_LATER_MOVEMENT_FAILED'; END IF;
 -- An anchor never certifies unknown legacy transactions after the reference.
 INSERT INTO inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,created_at) VALUES(store,item,'adjust',1,'2026-10-01T01:30:00+07:00');
 IF inventory_stock_at(item,reference)->>'quantity' IS NOT NULL OR NOT (inventory_stock_at(item,reference)->>'unverified_history')::boolean THEN RAISE EXCEPTION 'UNKNOWN_HISTORY_CERTIFIED'; END IF;
END $$;
SET request.jwt.claim.role='authenticated';
SELECT expect_stock_audit_error($q$SELECT get_inventory_stock_audit_balances(test_uuid(8100),'2026-09-30')$q$,'FORBIDDEN');
SELECT 'Initial count availability, supplemental counts, zero vs blank, date default, later movements and scope: PASS';
