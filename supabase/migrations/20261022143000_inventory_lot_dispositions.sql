-- Retain the original inspection. A hold release is a new accepted receipt,
-- financially posting only the released quantity and referencing the held lot.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE FUNCTION public.inventory_dispose_lot_v1(p_id uuid,p_store uuid,p_lot uuid,p_action text,p_quantity numeric,p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE prior inventory_lot_dispositions; lot inventory_lots; ord inventory_purchase_orders; original inventory_receipt_lines;
 loc inventory_locations; worker store_employees; input_hash text; outcome jsonb; receipt_id uuid; lines jsonb; target_state text; target_id uuid:=gen_random_uuid(); stock numeric;
BEGIN
 PERFORM procurement_actor(p_store);
 IF NOT can_verify_inventory_receipt(p_store) THEN RAISE EXCEPTION 'INVENTORY_LOT_DISPOSITION_FORBIDDEN'; END IF;
 IF p_id IS NULL OR p_action NOT IN('release','reject','return','waste','move') OR p_action IS NULL OR p_quantity IS NULL OR p_quantity<=0 OR p_quantity::text IN('NaN','Infinity','-Infinity') OR p_quantity<>round(p_quantity,3)
 OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object' OR octet_length(p_payload::text)>262144 OR length(btrim(coalesce(p_payload->>'reason',''))) NOT BETWEEN 5 AND 1000
 OR length(btrim(coalesce(p_payload->>'evidence_reference',''))) NOT BETWEEN 5 AND 500 THEN RAISE EXCEPTION 'INVENTORY_LOT_DISPOSITION_INVALID'; END IF;
 input_hash:=md5(jsonb_build_object('store',p_store,'lot',p_lot,'action',p_action,'quantity',p_quantity,'payload',p_payload,'actor',auth.uid())::text);
 PERFORM pg_advisory_xact_lock(hashtextextended('lot-disposition:'||p_id,0));
 SELECT * INTO prior FROM inventory_lot_dispositions WHERE id=p_id;
 IF FOUND THEN
  IF prior.payload_hash<>input_hash THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF;
  RETURN prior.result;
 END IF;
 SELECT * INTO lot FROM inventory_lots WHERE id=p_lot AND restaurant_id=p_store;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_LOT_NOT_FOUND'; END IF;
 SELECT * INTO original FROM inventory_receipt_lines WHERE id=lot.receipt_line_id;
 -- Same lock order as receiving/shortage issuance, then stock, then lot.
  SELECT o.* INTO ord FROM inventory_purchase_orders o JOIN inventory_purchase_order_lines l ON l.purchase_order_id=o.id WHERE l.id=original.purchase_order_line_id FOR UPDATE OF o;
 SELECT current_stock INTO stock FROM inventory_items WHERE id=lot.ingredient_id FOR UPDATE;
 SELECT * INTO lot FROM inventory_lots WHERE id=p_lot FOR UPDATE;
 IF lot.quantity_base<p_quantity OR lot.state NOT IN('available','held','rejected') THEN RAISE EXCEPTION 'INVENTORY_LOT_QUANTITY_CHANGED'; END IF;
 SELECT * INTO worker FROM store_employees WHERE id=nullif(p_payload->>'employee_id','')::uuid AND store_id=p_store AND is_active;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_COUNT_EMPLOYEE_REQUIRED'; END IF;
 IF p_action='release' AND (lot.state<>'held' OR original.id IS NULL OR ord.id IS NULL) THEN RAISE EXCEPTION 'INVENTORY_LOT_NOT_HELD'; END IF;
 IF p_action='reject' AND lot.state<>'held' THEN RAISE EXCEPTION 'INVENTORY_LOT_NOT_HELD'; END IF;
 IF p_action='return' AND lot.state='available' THEN RAISE EXCEPTION 'INVENTORY_USE_SUPPLIER_RETURN'; END IF;
 IF p_action IN('release','reject','move') THEN
  SELECT * INTO loc FROM inventory_locations WHERE id=nullif(p_payload->>'location_id','')::uuid AND restaurant_id=p_store AND is_active;
  IF loc.id IS NULL OR loc.kind IS DISTINCT FROM (CASE WHEN p_action='release' OR p_action='move' AND lot.state='available' THEN 'storage' WHEN p_action='reject' OR p_action='move' AND lot.state='rejected' THEN 'rejected' ELSE 'quarantine' END) THEN RAISE EXCEPTION 'INVENTORY_LOCATION_INVALID'; END IF;
 END IF;
 INSERT INTO inventory_lot_dispositions(id,restaurant_id,lot_id,action,quantity_base,payload_hash,payload,actor_id)
 VALUES(p_id,p_store,p_lot,p_action,p_quantity,input_hash,p_payload||jsonb_build_object('employee_snapshot',jsonb_build_object('id',worker.id,'name',worker.full_name,'number',worker.employee_number)),auth.uid());
 IF p_action='release' THEN
  receipt_id:=(p_payload->>'receipt_id')::uuid;
  IF receipt_id IS NULL OR (p_payload->>'expected_order_version')::integer IS DISTINCT FROM ord.row_version THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_STALE_VERSION'; END IF;
  UPDATE inventory_lots SET quantity_base=quantity_base-p_quantity WHERE id=p_lot;
  INSERT INTO inventory_lot_receipt_origins VALUES(receipt_id,p_id,p_lot,p_quantity);
  SELECT jsonb_agg(jsonb_build_object('purchase_order_line_id',l.id,'received_quantity_base',CASE WHEN l.id=original.purchase_order_line_id THEN p_quantity ELSE 0 END,'rejected_quantity_base',0,'held_quantity_base',0,
   'discrepancy_reason',p_payload->>'reason',
   'inspection',CASE WHEN l.id=original.purchase_order_line_id THEN coalesce(p_payload->'inspection','{}')||jsonb_build_object('employee_id',worker.id,'lots',jsonb_build_array(jsonb_build_object('code',lot.supplier_lot_code,'expiry_date',lot.expiry_date,'location_id',loc.id,'accepted',p_quantity,'held',0,'rejected',0))) ELSE jsonb_build_object('issue_type','none') END) ORDER BY l.id) INTO lines
  FROM inventory_purchase_order_lines l WHERE l.purchase_order_id=ord.id;
  outcome:=finalize_procurement_receipt(jsonb_build_object('p_purchase_order_id',ord.id,'p_receipt_id',receipt_id,'p_expected_order_version',ord.row_version,'p_expected_receipt_version',0,'p_idempotency_key','hold-release:'||p_id,'p_inspector_name',worker.full_name,
   'p_statement_storage_path',p_payload->>'statement_storage_path','p_statement_number',p_payload->>'statement_number','p_statement_date',p_payload->>'statement_date','p_memo',p_payload->>'reason','p_lines',lines));
  INSERT INTO inventory_lot_movements(lot_id,event_kind,event_id,quantity_base,created_by) VALUES(p_lot,'disposition',p_id,-p_quantity,auth.uid());
 ELSE
  target_state:=CASE p_action WHEN 'reject' THEN 'rejected' WHEN 'return' THEN 'returned' WHEN 'waste' THEN 'waste' ELSE lot.state END;
  IF p_action='waste' AND lot.state='available' THEN
   UPDATE inventory_items SET current_stock=current_stock-p_quantity,quantity=current_stock-p_quantity,updated_at=clock_timestamp() WHERE id=lot.ingredient_id;
   INSERT INTO inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,reference_id,note,created_by,performed_by_employee_id,stock_before,stock_after)
   VALUES(p_store,lot.ingredient_id,'waste',-p_quantity,'inventory_lot_disposition',p_id,p_payload->>'reason',auth.uid(),worker.id,stock,stock-p_quantity);
  ELSE
   UPDATE inventory_lots SET quantity_base=quantity_base-p_quantity WHERE id=p_lot;
   INSERT INTO inventory_lot_movements(lot_id,event_kind,event_id,quantity_base,created_by) VALUES(p_lot,'disposition',p_id,-p_quantity,auth.uid());
  END IF;
  INSERT INTO inventory_lots(id,restaurant_id,ingredient_id,location_id,supplier_lot_code,expiry_date,quantity_base,state,source_kind,source_id,source_component,receipt_line_id,parent_lot_id)
  VALUES(target_id,p_store,lot.ingredient_id,coalesce(loc.id,lot.location_id),lot.supplier_lot_code,lot.expiry_date,p_quantity,target_state,'disposition',p_id,1,lot.receipt_line_id,p_lot);
  INSERT INTO inventory_lot_movements(lot_id,event_kind,event_id,quantity_base,created_by) VALUES(target_id,'disposition',p_id,p_quantity,auth.uid());
  outcome:=jsonb_build_object('id',p_id,'lot_id',target_id,'state',target_state,'quantity_base',p_quantity);
 END IF;
 PERFORM inventory_queue_lot_reconciliation_v1(ARRAY[lot.ingredient_id]);
 UPDATE inventory_lot_dispositions SET result=outcome WHERE id=p_id;
 RETURN outcome;
END $$;
REVOKE ALL ON FUNCTION public.inventory_dispose_lot_v1(uuid,uuid,uuid,text,numeric,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.inventory_dispose_lot_v1(uuid,uuid,uuid,text,numeric,jsonb) TO authenticated;
COMMIT;
