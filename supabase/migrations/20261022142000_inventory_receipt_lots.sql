-- Physical receipt = accepted + held + rejected. Held quantities are excluded
-- from usable stock and shortage reservations until a recorded disposition.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
ALTER TABLE public.inventory_receipt_lines ADD COLUMN held_quantity_base numeric(12,3) NOT NULL DEFAULT 0 CHECK(held_quantity_base>=0 AND held_quantity_base::text NOT IN('NaN','Infinity','-Infinity'));
CREATE FUNCTION public.inventory_validate_receipt_lots_v1(p_store uuid,p_lines jsonb) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE lines jsonb; today date:=(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
BEGIN
 SELECT coalesce(jsonb_agg(x||jsonb_build_object('tracked',t.ingredient_id IS NOT NULL,'accepted',coalesce((x->>'accepted_quantity_base')::numeric,(x->>'received_quantity_base')::numeric-coalesce((x->>'rejected_quantity_base')::numeric,0)-coalesce((x->>'held_quantity_base')::numeric,0)))),'[]') INTO lines
 FROM jsonb_array_elements(p_lines)x JOIN inventory_purchase_order_lines ol ON ol.id=(x->>'purchase_order_line_id')::uuid
 JOIN inventory_products p ON p.id=ol.product_id AND p.restaurant_id=p_store LEFT JOIN inventory_lot_tracking t ON t.ingredient_id=p.inventory_item_id AND t.restaurant_id=p_store;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(lines)x WHERE coalesce((x->>'held_quantity_base')::numeric,0)<0 OR coalesce((x->>'held_quantity_base')::numeric,0)::text IN('NaN','Infinity','-Infinity')
 OR (x->>'accepted')::numeric<0 OR coalesce((x->>'held_quantity_base')::numeric,0)>0 AND (NOT (x->>'tracked')::boolean OR length(btrim(coalesce(x->>'discrepancy_reason','')))<5 OR x->'inspection'->>'issue_type'='none')) THEN RAISE EXCEPTION 'INVENTORY_HOLD_QUANTITY_OR_REASON_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(lines)x WHERE (x->>'tracked')::boolean AND (x->>'received_quantity_base')::numeric>0 AND
 (jsonb_typeof(x->'inspection'->'lots') IS DISTINCT FROM 'array' OR jsonb_array_length(x->'inspection'->'lots') NOT BETWEEN 1 AND 20)) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LOTS_REQUIRED'; END IF;
 IF EXISTS(WITH totals AS(SELECT x,sum(coalesce((l->>'accepted')::numeric,0)) accepted,sum(coalesce((l->>'held')::numeric,0)) held,sum(coalesce((l->>'rejected')::numeric,0)) rejected
 FROM jsonb_array_elements(lines)x CROSS JOIN LATERAL jsonb_array_elements(coalesce(x->'inspection'->'lots','[]'))l WHERE (x->>'tracked')::boolean GROUP BY x)
 SELECT 1 FROM totals WHERE (accepted,held,rejected) IS DISTINCT FROM ((x->>'accepted')::numeric,coalesce((x->>'held_quantity_base')::numeric,0),coalesce((x->>'rejected_quantity_base')::numeric,0))) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LOT_TOTAL_MISMATCH'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(lines)x CROSS JOIN LATERAL jsonb_array_elements(coalesce(x->'inspection'->'lots','[]'))l
 LEFT JOIN inventory_locations loc ON loc.id=nullif(l->>'location_id','')::uuid AND loc.restaurant_id=p_store AND loc.kind='storage' AND loc.is_active
 LEFT JOIN inventory_locations hold ON hold.id=nullif(l->>'held_location_id','')::uuid AND hold.restaurant_id=p_store AND hold.kind='quarantine' AND hold.is_active
 LEFT JOIN inventory_locations reject_location ON reject_location.id=nullif(l->>'rejected_location_id','')::uuid AND reject_location.restaurant_id=p_store AND reject_location.kind='rejected' AND reject_location.is_active
 WHERE (x->>'tracked')::boolean AND (length(btrim(coalesce(l->>'code',''))) NOT BETWEEN 1 AND 160
 OR jsonb_typeof(l->'accepted') IS DISTINCT FROM 'number' OR jsonb_typeof(l->'held') IS DISTINCT FROM 'number' OR jsonb_typeof(l->'rejected') IS DISTINCT FROM 'number'
 OR least((l->>'accepted')::numeric,(l->>'held')::numeric,(l->>'rejected')::numeric)<0
 OR (l->>'accepted')::numeric+(l->>'held')::numeric+(l->>'rejected')::numeric<=0
 OR (l->>'accepted')::numeric<>round((l->>'accepted')::numeric,3) OR (l->>'held')::numeric<>round((l->>'held')::numeric,3) OR (l->>'rejected')::numeric<>round((l->>'rejected')::numeric,3)
 OR ((l->>'accepted')::numeric>0 AND (loc.id IS NULL OR nullif(l->>'expiry_date','')::date<today))
 OR ((l->>'held')::numeric>0 AND hold.id IS NULL) OR ((l->>'rejected')::numeric>0 AND reject_location.id IS NULL)
 OR ((l->>'accepted')::numeric>0 AND coalesce((x->'inspection'->'quality_snapshot'->'criteria'->>'expiry_required')::boolean,false) AND
 (nullif(l->>'expiry_date','') IS NULL OR (l->>'expiry_date')::date<today+(x->'inspection'->'quality_snapshot'->'criteria'->>'min_remaining_days')::integer)))) THEN RAISE EXCEPTION 'INVENTORY_RECEIPT_LOT_INVALID'; END IF;
END $$;

CREATE FUNCTION public.inventory_capture_quarantine_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
 WITH physical AS MATERIALIZED(SELECT r.restaurant_id,rl.id line_id,p.inventory_item_id,l.value lot,l.ordinality component,kind.state,
  CASE WHEN kind.state='held' THEN (l.value->>'held')::numeric ELSE (l.value->>'rejected')::numeric END qty,
  CASE WHEN kind.state='held' THEN (l.value->>'held_location_id')::uuid ELSE (l.value->>'rejected_location_id')::uuid END location_id
 FROM new_lot_receipts r JOIN old_lot_receipts before_row ON before_row.id=r.id JOIN inventory_receipt_lines rl ON rl.receipt_id=r.id
 JOIN inventory_products p ON p.id=rl.product_id JOIN inventory_lot_tracking t ON t.ingredient_id=p.inventory_item_id
 CROSS JOIN LATERAL jsonb_array_elements(coalesce(rl.inspection->'lots','[]')) WITH ORDINALITY l(value,ordinality)
 CROSS JOIN (VALUES('held'),('rejected'))kind(state) WHERE r.status='confirmed' AND before_row.status<>'confirmed'),
 created AS(INSERT INTO inventory_lots(id,restaurant_id,ingredient_id,location_id,supplier_lot_code,expiry_date,quantity_base,state,source_kind,source_id,source_component,receipt_line_id)
 SELECT md5(line_id::text||':'||component||':'||state)::uuid,restaurant_id,inventory_item_id,location_id,lot->>'code',nullif(lot->>'expiry_date','')::date,qty,state,'receipt',line_id,component::integer,line_id FROM physical WHERE qty>0 RETURNING *)
 INSERT INTO inventory_lot_movements(lot_id,event_kind,event_id,quantity_base,created_by) SELECT id,'physical_receipt',receipt_line_id,quantity_base,auth.uid() FROM created;
 RETURN NULL;
END $$;
CREATE TRIGGER inventory_capture_quarantine AFTER UPDATE ON public.inventory_receipts REFERENCING OLD TABLE AS old_lot_receipts NEW TABLE AS new_lot_receipts FOR EACH STATEMENT EXECUTE FUNCTION public.inventory_capture_quarantine_v1();

CREATE FUNCTION public.inventory_held_by_order_line_v1(p_ids uuid[]) RETURNS TABLE(order_line_id uuid,quantity_base numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT rl.purchase_order_line_id,sum(l.quantity_base) FROM inventory_lots l JOIN inventory_receipt_lines rl ON rl.id=l.receipt_line_id
 WHERE l.state='held' AND l.quantity_base>0 AND rl.purchase_order_line_id=ANY(p_ids) GROUP BY rl.purchase_order_line_id;
$$;
CREATE FUNCTION public.inventory_guard_held_shortage_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE ids uuid[]; newly_issued jsonb:='[]';
BEGIN
 SELECT array_agg(DISTINCT original_order_line_id) INTO ids FROM new_hold_allocations WHERE status IN('reserved','issued');
 IF ids IS NULL THEN RETURN NULL; END IF;
 PERFORM 1 FROM inventory_purchase_orders WHERE id IN(SELECT purchase_order_id FROM inventory_purchase_order_lines WHERE id=ANY(ids)) ORDER BY id FOR UPDATE;
 IF TG_OP='UPDATE' THEN
  SELECT coalesce(jsonb_agg(jsonb_build_object('line',n.original_order_line_id,'qty',n.quantity_base)),'[]') INTO newly_issued FROM new_hold_allocations n JOIN old_hold_allocations before_row ON before_row.id=n.id WHERE n.status='issued' AND before_row.status='reserved';
 END IF;
 IF EXISTS(WITH accepted AS(SELECT rl.purchase_order_line_id,sum(rl.accepted_quantity_base) qty FROM inventory_receipt_lines rl JOIN inventory_receipts r ON r.id=rl.receipt_id AND r.status='confirmed' WHERE rl.purchase_order_line_id=ANY(ids) GROUP BY rl.purchase_order_line_id),
 reserved AS(SELECT original_order_line_id,sum(quantity_base) qty FROM procurement_shortage_allocations WHERE original_order_line_id=ANY(ids) AND status='reserved' GROUP BY original_order_line_id),
 issued AS(SELECT (x->>'line')::uuid line,sum((x->>'qty')::numeric) qty FROM jsonb_array_elements(newly_issued)x GROUP BY x->>'line')
 SELECT 1 FROM inventory_purchase_order_lines ol JOIN inventory_held_by_order_line_v1(ids) held ON held.order_line_id=ol.id
 LEFT JOIN accepted a ON a.purchase_order_line_id=ol.id LEFT JOIN reserved r ON r.original_order_line_id=ol.id LEFT JOIN issued i ON i.line=ol.id
 WHERE ol.id=ANY(ids) AND coalesce(r.qty,0)+coalesce(i.qty,0)>greatest(0,ol.ordered_quantity_base-ol.cancelled_quantity_base-coalesce(a.qty,0)-held.quantity_base)) THEN RAISE EXCEPTION 'PROCUREMENT_SHORTAGE_EXCLUDES_HELD'; END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER inventory_guard_held_shortage_insert AFTER INSERT ON public.procurement_shortage_allocations REFERENCING NEW TABLE AS new_hold_allocations FOR EACH STATEMENT EXECUTE FUNCTION public.inventory_guard_held_shortage_v1();
CREATE TRIGGER inventory_guard_held_shortage_update AFTER UPDATE ON public.procurement_shortage_allocations REFERENCING OLD TABLE AS old_hold_allocations NEW TABLE AS new_hold_allocations FOR EACH STATEMENT EXECUTE FUNCTION public.inventory_guard_held_shortage_v1();

DO $$ DECLARE d text; BEGIN
 d:=pg_get_functiondef('public.procurement_enrich_quality_lines_v1(uuid,jsonb)'::regprocedure);
 d:=replace(d,' RETURN result;', 'SELECT jsonb_agg(x||jsonb_build_object(''accepted_quantity_base'',(x->>''received_quantity_base'')::numeric-coalesce((x->>''rejected_quantity_base'')::numeric,0)-coalesce((x->>''held_quantity_base'')::numeric,0))) INTO result FROM jsonb_array_elements(result)x; PERFORM public.inventory_validate_receipt_lots_v1(p_store,result); RETURN result;'); EXECUTE d;
 d:=pg_get_functiondef('public.procurement_validate_inspection_batch(uuid,jsonb)'::regprocedure);
 d:=replace(d,' PERFORM procurement_validate_inspection_before_quality(p_store_id,p_lines);', ' PERFORM public.inventory_validate_receipt_lots_v1(p_store_id,p_lines); PERFORM procurement_validate_inspection_before_quality(p_store_id,p_lines);'); EXECUTE d;
 d:=pg_get_functiondef('public.submit_inventory_receipt_batch(uuid,uuid,integer,integer,text,jsonb,text,text,text,date,text)'::regprocedure);
 IF position('rejected_quantity_base,actual_unit_price,discrepancy_reason,inspection,expected_quantity_base_snapshot)' IN d)=0 THEN RAISE EXCEPTION 'LOT_SUBMISSION_PATCH_MISMATCH'; END IF;
 d:=replace(d,'rejected_quantity_base,actual_unit_price,discrepancy_reason,inspection,expected_quantity_base_snapshot)', 'rejected_quantity_base,held_quantity_base,actual_unit_price,discrepancy_reason,inspection,expected_quantity_base_snapshot)');
 d:=replace(d,'(x->>''received_quantity_base'')::numeric-COALESCE((x->>''rejected_quantity_base'')::numeric,0),COALESCE((x->>''rejected_quantity_base'')::numeric,0),COALESCE((x->>''actual_unit_price'')::numeric,ol.unit_price)',
 '(x->>''received_quantity_base'')::numeric-COALESCE((x->>''rejected_quantity_base'')::numeric,0)-coalesce((x->>''held_quantity_base'')::numeric,0),COALESCE((x->>''rejected_quantity_base'')::numeric,0),coalesce((x->>''held_quantity_base'')::numeric,0),COALESCE((x->>''actual_unit_price'')::numeric,ol.unit_price)');
 d:=replace(d,'rejected_quantity_base=EXCLUDED.rejected_quantity_base,actual_unit_price', 'rejected_quantity_base=EXCLUDED.rejected_quantity_base,held_quantity_base=EXCLUDED.held_quantity_base,actual_unit_price'); EXECUTE d;
 d:=pg_get_functiondef('public.verify_inventory_receipt_p1(uuid,integer,text,jsonb,text)'::regprocedure);
 d:=replace(d,'+COALESCE((x->>''rejected_quantity_base'')::numeric,l.rejected_quantity_base),', '+COALESCE((x->>''rejected_quantity_base'')::numeric,l.rejected_quantity_base)+l.held_quantity_base,'); EXECUTE d;
 d:=pg_get_functiondef('public.procurement_shortages(uuid,jsonb,jsonb)'::regprocedure);
 d:=replace(d,'COALESCE(a.qty,0)-COALESCE(r.qty,0)', 'COALESCE(a.qty,0)-coalesce(held.quantity_base,0)-COALESCE(r.qty,0)');
 d:=replace(d,'LEFT JOIN accepted a ON a.purchase_order_line_id=ol.id', 'LEFT JOIN public.inventory_held_by_order_line_v1(ARRAY(SELECT l.id FROM public.inventory_purchase_order_lines l JOIN orders o2 ON o2.id=l.purchase_order_id)) held ON held.order_line_id=ol.id LEFT JOIN accepted a ON a.purchase_order_line_id=ol.id');
 d:=replace(d,'COALESCE(r.own,0) reserved_quantity_base', 'coalesce(held.quantity_base,0) held_quantity_base,COALESCE(r.own,0) reserved_quantity_base'); EXECUTE d;
 d:=pg_get_functiondef('public.procurement_create_receipt_report(uuid)'::regprocedure);
 d:=replace(d,'COALESCE(rl.received_quantity_base,0)/ol.order_unit_quantity_base_snapshot received_quantity,',
 'CASE WHEN origin.receipt_id IS NULL THEN COALESCE(rl.received_quantity_base,0) ELSE 0 END/ol.order_unit_quantity_base_snapshot received_quantity, CASE WHEN origin.receipt_id IS NULL THEN 0 ELSE COALESCE(rl.accepted_quantity_base,0) END/ol.order_unit_quantity_base_snapshot released_quantity, COALESCE(rl.held_quantity_base,0)/ol.order_unit_quantity_base_snapshot held_quantity,');
 d:=replace(d,'LEFT JOIN public.inventory_receipt_lines rl ON rl.receipt_id=cr.id AND rl.purchase_order_line_id=ol.id)', 'LEFT JOIN public.inventory_receipt_lines rl ON rl.receipt_id=cr.id AND rl.purchase_order_line_id=ol.id LEFT JOIN public.inventory_lot_receipt_origins origin ON origin.receipt_id=cr.id)');
 d:=replace(d,'''receipt_id'',cr.id,''purchase_order_id''', '''receipt_id'',cr.id,''receipt_origin'',CASE WHEN EXISTS(SELECT 1 FROM public.inventory_lot_receipt_origins o WHERE o.receipt_id=cr.id) THEN ''hold_release'' ELSE ''delivery'' END,''purchase_order_id'''); EXECUTE d;
END $$;
REVOKE ALL ON FUNCTION public.inventory_validate_receipt_lots_v1(uuid,jsonb),public.inventory_capture_quarantine_v1(),public.inventory_held_by_order_line_v1(uuid[]),public.inventory_guard_held_shortage_v1() FROM PUBLIC,anon,authenticated,service_role;
COMMIT;
