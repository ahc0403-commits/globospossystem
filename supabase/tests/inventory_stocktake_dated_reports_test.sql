SET request.jwt.claim.role='service_role';
-- All quantities below are fictitious SAMPLE counts in an isolated database.
UPDATE inventory_items SET current_stock=100,quantity=100,created_at='2026-09-01' WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
DELETE FROM inventory_stock_movements WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
UPDATE inventory_stock_checkpoints SET opening_stock=100,tracked_from='2026-09-29' WHERE restaurant_id='3a268807-771f-4fd4-84fe-e1b0b00de40a';
DO $$ DECLARE store uuid:='3a268807-771f-4fd4-84fe-e1b0b00de40a'; s jsonb; lines jsonb; preview jsonb; result jsonb; report jsonb; item uuid; pid uuid; transactions int; original_report jsonb;
BEGIN
 s:=prepare_inventory_stock_audit_v2(store,'2026-09-30','2026-09-30T23:00:00+07:00');
 PERFORM expect_stock_audit_error(format('SELECT save_inventory_stock_audit_v2(%L,%L,1,''[]''::jsonb,false)',store,s->>'id'),'DATED_FORMAT_REQUIRED');
 item:=(s->'snapshot'->0->>'inventory_item_id')::uuid; pid:=(s->'snapshot'->0->>'product_id')::uuid;
 SELECT jsonb_agg(jsonb_build_object('product_id',x->>'product_id','actual_quantity_base',80,'counted_at','2026-09-30T16:00:00Z','excluded_reason',null,'memo',null)) INTO lines FROM jsonb_array_elements(s->'snapshot') x;
 UPDATE inventory_items SET current_stock=current_stock+30 WHERE id=item;
 INSERT INTO inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,effective_at) VALUES(store,item,'restock',30,'test_receipt','2026-10-01T00:01:00+07:00');
 UPDATE inventory_items SET current_stock=current_stock-20 WHERE id=item;
 INSERT INTO inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,effective_at) VALUES(store,item,'deduct',-20,'test_sale','2026-10-01T00:02:00+07:00');
 UPDATE inventory_items SET current_stock=current_stock-5 WHERE id=item;
 INSERT INTO inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,effective_at) VALUES(store,item,'waste',-5,'test_waste','2026-10-01T00:03:00+07:00');
 preview:=preview_inventory_stock_audit_v3(store,(s->>'id')::uuid,lines);
 IF NOT (preview->>'can_complete')::boolean THEN RAISE EXCEPTION 'PREVIEW_BLOCKED %',preview; END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(preview->'rows') r WHERE r->>'product_id'=pid::text AND (r->>'baseline_quantity_base')::numeric=100 AND (r->>'variance_quantity_base')::numeric=-20 AND (r->>'current_after_base')::numeric=85) THEN RAISE EXCEPTION 'DATED_FORMULA_FAILED'; END IF;
 result:=save_inventory_stock_audit_v3(store,(s->>'id')::uuid,1,lines,false);
 IF (SELECT current_stock FROM inventory_items WHERE id=item)<>105 THEN RAISE EXCEPTION 'DRAFT_MUTATED_STOCK'; END IF;
 preview:=preview_inventory_stock_audit_v3(store,(s->>'id')::uuid,lines);
 -- A final-row error must roll back every change.
 PERFORM expect_stock_audit_error(format('SELECT save_inventory_stock_audit_v3(%L,%L,2,%L,true,NULL,%L)',store,s->>'id',jsonb_set(lines,ARRAY[(jsonb_array_length(lines)-1)::text,'actual_quantity_base'],'-1'),preview->>'token'),'ACTUAL_INVALID');
 IF (SELECT current_stock FROM inventory_items WHERE id=item)<>105 THEN RAISE EXCEPTION 'PARTIAL_APPLY'; END IF;
 result:=save_inventory_stock_audit_v3(store,(s->>'id')::uuid,2,lines,true,NULL,preview->>'token');
 IF result->>'status'<>'completed' OR (SELECT current_stock FROM inventory_items WHERE id=item)<>85 THEN RAISE EXCEPTION 'NEXT_DAY_LOST'; END IF;
 IF NOT EXISTS(SELECT 1 FROM inventory_transactions WHERE reference_id=(s->>'id')::uuid AND ingredient_id=item AND quantity_g=-20 AND effective_date='2026-09-30' AND effective_at='2026-09-30T16:00:00Z') THEN RAISE EXCEPTION 'WRONG_EFFECTIVE_DATE'; END IF;
 SELECT count(*) INTO transactions FROM inventory_transactions;
 result:=save_inventory_stock_audit_v3(store,(s->>'id')::uuid,2,lines,true,NULL,preview->>'token');
 IF (SELECT count(*) FROM inventory_transactions)<>transactions THEN RAISE EXCEPTION 'DUPLICATE_APPLY'; END IF;
 original_report:=result->'report';
 UPDATE inventory_items SET cost_per_unit=999,current_stock=current_stock-2 WHERE id=item;
 report:=get_inventory_stock_audit_report(store,(s->>'id')::uuid);
 IF report->'report' IS DISTINCT FROM original_report OR jsonb_array_length(report->'movements')<>4 THEN RAISE EXCEPTION 'REPORT_CHANGED_OR_DOUBLE_COUNTED'; END IF;
 -- Backdated events after completion cannot silently double-consume actual stock.
 BEGIN
  UPDATE inventory_items SET current_stock=current_stock-1 WHERE id=item;
  INSERT INTO inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,effective_at) VALUES(store,item,'deduct',-1,'2026-09-30T15:59:00Z');
  RAISE EXCEPTION 'LATE_EVENT_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'INVENTORY_STOCK_LATE_EVENT_REQUIRES_REVIEW' THEN RAISE; END IF; END;
 IF (SELECT current_stock FROM inventory_items WHERE id=item)<>83 THEN RAISE EXCEPTION 'LATE_EVENT_PARTIAL_WRITE'; END IF;
 s:=prepare_inventory_stock_audit_v2(store,'2026-09-30','2026-09-30T22:00:00+07:00');
 preview:=preview_inventory_stock_audit_v3(store,(s->>'id')::uuid,lines);
 IF (preview->>'can_complete')::boolean OR NOT EXISTS(SELECT 1 FROM jsonb_array_elements(preview->'rows') r WHERE r->>'issue'='NEWER_COUNT_EXISTS') THEN RAISE EXCEPTION 'OLD_COUNT_REPLACED_NEW'; END IF;
 PERFORM cancel_inventory_stock_audit(store,(s->>'id')::uuid,1);
END $$;

DO $$ DECLARE store uuid:='3a268807-771f-4fd4-84fe-e1b0b00de40a'; s jsonb; lines jsonb; preview jsonb; item uuid; t timestamptz:=clock_timestamp();
BEGIN
 -- Observations at different times are normalized to the shared reference.
 s:=prepare_inventory_stock_audit_v2(store,(t AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,t);
 item:=(s->'snapshot'->0->>'inventory_item_id')::uuid;
 UPDATE inventory_items SET current_stock=current_stock-3 WHERE id=item;
 INSERT INTO inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,effective_at) VALUES(store,item,'deduct',-3,clock_timestamp());
 SELECT jsonb_agg(jsonb_build_object('product_id',x->>'product_id','actual_quantity_base',CASE WHEN x->>'inventory_item_id'=item::text THEN 10 ELSE 80 END,'counted_at',clock_timestamp())) INTO lines FROM jsonb_array_elements(s->'snapshot') x;
 preview:=preview_inventory_stock_audit_v3(store,(s->>'id')::uuid,lines);
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(preview->'rows') x WHERE x->>'inventory_item_id'=item::text AND (x->>'actual_quantity_base')::numeric=13 AND (x->>'current_after_base')::numeric=10) THEN RAISE EXCEPTION 'OBSERVATION_NORMALIZATION_FAILED'; END IF;
 -- Future template is allowed, completion before the reference is not.
 s:=prepare_inventory_stock_audit_v2(store,((clock_timestamp()+interval '1 hour') AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,clock_timestamp()+interval '1 hour');
 SELECT jsonb_agg(jsonb_build_object('product_id',x->>'product_id','actual_quantity_base',1,'counted_at',clock_timestamp())) INTO lines FROM jsonb_array_elements(s->'snapshot') x;
 preview:=preview_inventory_stock_audit_v3(store,(s->>'id')::uuid,lines);
 IF (preview->>'can_complete')::boolean THEN RAISE EXCEPTION 'FUTURE_COMPLETED'; END IF;
END $$;

DO $$ DECLARE store uuid:=test_uuid(7000); item uuid:=test_uuid(7001); pid uuid:=test_uuid(7002); s jsonb; lines jsonb; preview jsonb; result jsonb; t timestamptz:=clock_timestamp()-interval '10 minutes';
BEGIN
 INSERT INTO restaurants(id,brand_id,name) VALUES(store,'a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878','Isolated initial count');
 INSERT INTO inventory_items(id,restaurant_id,name,quantity,current_stock,unit) VALUES(item,store,'New item',100,100,'ea');
 INSERT INTO inventory_products(id,restaurant_id,brand_id,inventory_item_id,product_code,name,stock_unit,base_unit,base_unit_factor) VALUES(pid,store,'a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878',item,'GO001','New item','ea','ea',1);
 s:=prepare_inventory_stock_audit_v2(store,(t AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,t);
 lines:=jsonb_build_array(jsonb_build_object('product_id',pid,'actual_quantity_base',80,'counted_at',s->>'effective_at'));
 UPDATE inventory_items SET current_stock=current_stock+12 WHERE id=item;
 preview:=preview_inventory_stock_audit_v3(store,(s->>'id')::uuid,lines);
 IF (preview->>'can_complete')::boolean THEN RAISE EXCEPTION 'MISSING_BASELINE_AUTO_COMPLETED'; END IF;
 preview:=preview_inventory_stock_audit_v3(store,(s->>'id')::uuid,lines,true);
 result:=save_inventory_stock_audit_v3(store,(s->>'id')::uuid,1,lines,true,NULL,preview->>'token',true);
 IF (SELECT current_stock FROM inventory_items WHERE id=item)<>92 OR (SELECT theoretical_quantity_base FROM inventory_stock_audit_lines WHERE session_id=(s->>'id')::uuid AND product_id=pid) IS NOT NULL OR result->'report'->'rows'->0->>'variance_quantity_base' IS NOT NULL THEN RAISE EXCEPTION 'INITIAL_BASELINE_INVENTED_OR_MOVEMENT_LOST'; END IF;
 -- Preserve unknown history instead of pretending missing movements equal zero.
 UPDATE inventory_items SET created_at=t-interval '1 day' WHERE id=item;
 UPDATE inventory_stock_checkpoints SET tracked_from=clock_timestamp()+interval '1 day' WHERE ingredient_id=item;
 INSERT INTO inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,created_at) VALUES(store,item,'adjust',1,clock_timestamp());
 s:=prepare_inventory_stock_audit_v2(store,(clock_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,clock_timestamp());
 lines:=jsonb_build_array(jsonb_build_object('product_id',pid,'actual_quantity_base',0,'counted_at',s->>'effective_at'));
 -- The unknown transaction was before this reference, so create one after it.
 INSERT INTO inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,created_at) VALUES(store,item,'adjust',1,clock_timestamp());
 preview:=preview_inventory_stock_audit_v3(store,(s->>'id')::uuid,lines,true,true);
 IF (preview->>'can_complete')::boolean OR preview->'rows'->0->>'issue'<>'HISTORY_UNVERIFIED' THEN RAISE EXCEPTION 'UNKNOWN_HISTORY_ACCEPTED'; END IF;
END $$;

SET request.jwt.claim.role='authenticated';
SELECT expect_stock_audit_error($q$SELECT list_inventory_stock_audits('3a268807-771f-4fd4-84fe-e1b0b00de40a')$q$,'FORBIDDEN');
SELECT expect_stock_audit_error($q$SELECT prepare_inventory_stock_audit_v2('3a268807-771f-4fd4-84fe-e1b0b00de40a','2026-09-30','2026-09-30T16:00:00Z')$q$,'FORBIDDEN');
SELECT 'Dated counts, next-day ±, immutable report, draft, idempotency, row atomicity, late/newer counts, observation time, store scope: PASS';
