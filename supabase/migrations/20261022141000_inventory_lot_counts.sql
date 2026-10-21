-- Explicit opening/count documents. Carry-forward stock is not a second receipt.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE TABLE public.inventory_lot_count_rows (
 count_id uuid NOT NULL REFERENCES public.inventory_lot_counts(id) ON DELETE CASCADE,
 ingredient_id uuid NOT NULL REFERENCES public.inventory_items(id) ON DELETE CASCADE,
 data jsonb NOT NULL,created_at timestamptz NOT NULL DEFAULT clock_timestamp(),PRIMARY KEY(count_id,ingredient_id)
);
CREATE INDEX inventory_lot_count_rows_latest ON public.inventory_lot_count_rows(ingredient_id,created_at DESC,count_id DESC);
ALTER TABLE public.inventory_lot_count_rows ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_lot_count_rows FROM PUBLIC,anon,authenticated;
CREATE TRIGGER inventory_lot_count_rows_immutable BEFORE UPDATE ON public.inventory_lot_count_rows FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE FUNCTION public.admin_record_inventory_lot_count_v1(p_id uuid,p_store uuid,p_employee uuid,p_rows jsonb,p_reason text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE previous inventory_lot_counts; worker store_employees; input_hash text; rows_data jsonb; ids uuid[]; was_tracked uuid[];
BEGIN
 PERFORM require_brand_admin_v1();
 IF p_id IS NULL OR jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 100 OR octet_length(p_rows::text)>524288 OR length(btrim(coalesce(p_reason,''))) NOT BETWEEN 5 AND 1000 THEN RAISE EXCEPTION 'INVENTORY_COUNT_INPUT_INVALID'; END IF;
 input_hash:=md5(jsonb_build_object('store',p_store,'employee',p_employee,'rows',p_rows,'reason',btrim(p_reason),'actor',auth.uid())::text);
 PERFORM pg_advisory_xact_lock(hashtextextended('inventory-count:'||p_id,0));
 SELECT * INTO previous FROM inventory_lot_counts WHERE id=p_id;
 IF FOUND THEN
  IF previous.input_hash<>input_hash THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF;
  RETURN to_jsonb(previous);
 END IF;
 SELECT * INTO worker FROM store_employees WHERE id=p_employee AND store_id=p_store AND is_active;
 IF NOT FOUND THEN RAISE EXCEPTION 'INVENTORY_COUNT_EMPLOYEE_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x LEFT JOIN inventory_products p ON p.id=(x->>'product_id')::uuid AND p.restaurant_id=p_store AND p.is_active AND p.receipt_classification='stock'
 LEFT JOIN inventory_items i ON i.id=p.inventory_item_id AND i.restaurant_id=p_store AND i.is_active
 WHERE p.id IS NULL OR i.id IS NULL OR i.id::text IS DISTINCT FROM x->>'inventory_item_id' OR p.base_unit IS DISTINCT FROM x->>'unit'
 OR jsonb_typeof(x->'actual_quantity_base') IS DISTINCT FROM 'number' OR (x->>'actual_quantity_base')::numeric<0 OR (x->>'actual_quantity_base')::numeric<>round((x->>'actual_quantity_base')::numeric,3)
 OR jsonb_typeof(x->'expected_stock') IS DISTINCT FROM 'number' OR jsonb_typeof(x->'unit_cost_base') IS DISTINCT FROM 'number' OR (x->>'unit_cost_base')::numeric<0
 OR length(btrim(coalesce(x->>'cost_source',''))) NOT BETWEEN 5 AND 500 OR jsonb_typeof(x->'track_lots') IS DISTINCT FROM 'boolean'
 OR nullif(x->>'counted_at','') IS NULL OR (x->>'counted_at')::timestamptz>clock_timestamp()+interval '5 minutes'
 OR (x->>'counted_at')::timestamptz<clock_timestamp()-interval '1 day') THEN RAISE EXCEPTION 'INVENTORY_COUNT_INPUT_INVALID'; END IF;
 IF EXISTS(SELECT x->>'inventory_item_id' FROM jsonb_array_elements(p_rows)x GROUP BY x->>'inventory_item_id' HAVING count(*)>1) THEN RAISE EXCEPTION 'INVENTORY_COUNT_DUPLICATE_INGREDIENT'; END IF;
 SELECT array_agg((x->>'inventory_item_id')::uuid) INTO ids FROM jsonb_array_elements(p_rows)x;
 PERFORM 1 FROM inventory_items WHERE id=ANY(ids) ORDER BY id FOR UPDATE;
 SELECT array_agg(ingredient_id) INTO was_tracked FROM inventory_lot_tracking WHERE ingredient_id=ANY(ids);
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x JOIN inventory_items i ON i.id=(x->>'inventory_item_id')::uuid
 WHERE coalesce(i.current_stock,0)<>(x->>'expected_stock')::numeric OR i.updated_at>(x->>'counted_at')::timestamptz
 OR EXISTS(SELECT 1 FROM inventory_transactions tr WHERE tr.ingredient_id=i.id AND tr.created_at>(x->>'counted_at')::timestamptz)) THEN RAISE EXCEPTION 'INVENTORY_COUNT_STOCK_CHANGED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x WHERE (x->>'inventory_item_id')::uuid=ANY(was_tracked) AND NOT (x->>'track_lots')::boolean) THEN RAISE EXCEPTION 'INVENTORY_LOT_TRACKING_CANNOT_DISABLE'; END IF;
 -- Do not interrupt receiving for POs issued before lot tracking was enabled.
 IF EXISTS(SELECT 1 FROM inventory_purchase_order_lines l JOIN inventory_purchase_orders o ON o.id=l.purchase_order_id JOIN inventory_products p ON p.id=l.product_id
 JOIN jsonb_array_elements(p_rows)x ON (x->>'inventory_item_id')::uuid=p.inventory_item_id AND (x->>'track_lots')::boolean
 WHERE o.status IN('draft','submitted','store_approved','brand_approved','office_approved','ordered','partially_received') AND NOT coalesce(p.inventory_item_id=ANY(was_tracked),false)) THEN RAISE EXCEPTION 'INVENTORY_LOT_EXISTING_PO_MUST_DRAIN'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x WHERE (x->>'track_lots')::boolean AND (jsonb_typeof(x->'lots') IS DISTINCT FROM 'array' OR jsonb_array_length(x->'lots')>100)) THEN RAISE EXCEPTION 'INVENTORY_COUNT_LOTS_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x WHERE (x->>'track_lots')::boolean AND (x->>'actual_quantity_base')::numeric<>coalesce((SELECT sum((l->>'quantity_base')::numeric) FROM jsonb_array_elements(x->'lots')l),0)) THEN RAISE EXCEPTION 'INVENTORY_COUNT_LOT_TOTAL_MISMATCH'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x CROSS JOIN LATERAL jsonb_array_elements(coalesce(x->'lots','[]'))l
 LEFT JOIN inventory_locations loc ON loc.id=(l->>'location_id')::uuid AND loc.restaurant_id=p_store AND loc.is_active AND loc.kind='storage'
 WHERE (x->>'track_lots')::boolean AND (loc.id IS NULL OR jsonb_typeof(l->'quantity_base') IS DISTINCT FROM 'number' OR (l->>'quantity_base')::numeric<=0
 OR (l->>'quantity_base')::numeric<>round((l->>'quantity_base')::numeric,3) OR nullif(l->>'expiry_date','')::date<(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
 OR (nullif(btrim(l->>'code'),'') IS NULL AND NOT (coalesce((x->>'acknowledge_unknown_legacy')::boolean,false) AND (x->>'expected_stock')::numeric>0))
 OR length(coalesce(l->>'code',''))>160)) THEN RAISE EXCEPTION 'INVENTORY_COUNT_LOT_INVALID'; END IF;
 -- Every active purchasing alias of a tracked ingredient must explicitly use lots.
 IF EXISTS(WITH latest AS(SELECT DISTINCT ON(product_id) product_id,criteria FROM procurement_quality_profiles WHERE restaurant_id=p_store ORDER BY product_id,revision DESC)
 SELECT 1 FROM inventory_products p JOIN jsonb_array_elements(p_rows)x ON (x->>'inventory_item_id')::uuid=p.inventory_item_id AND (x->>'track_lots')::boolean
 LEFT JOIN latest q ON q.product_id=p.id WHERE p.is_active AND q.criteria->>'lot_required' IS DISTINCT FROM 'true') THEN RAISE EXCEPTION 'INVENTORY_LOT_CRITERIA_REQUIRED'; END IF;
 -- Known opening lots obey the approved expiry requirement; historical unknown
 -- stock remains explicitly marked, never assigned a fictitious supplier lot.
 IF EXISTS(WITH latest AS(SELECT DISTINCT ON(product_id) product_id,criteria FROM procurement_quality_profiles WHERE restaurant_id=p_store ORDER BY product_id,revision DESC)
 SELECT 1 FROM jsonb_array_elements(p_rows)x JOIN latest q ON q.product_id=(x->>'product_id')::uuid CROSS JOIN LATERAL jsonb_array_elements(coalesce(x->'lots','[]'))l
 WHERE (x->>'track_lots')::boolean AND (q.criteria->>'expiry_required')::boolean AND nullif(btrim(l->>'code'),'') IS NOT NULL AND nullif(l->>'expiry_date','') IS NULL) THEN RAISE EXCEPTION 'INVENTORY_COUNT_LOT_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM inventory_lots l WHERE l.ingredient_id=ANY(ids) AND l.state IN('held','rejected') AND l.quantity_base>0) THEN RAISE EXCEPTION 'INVENTORY_COUNT_QUARANTINE_SEPARATE'; END IF;
 IF EXISTS(SELECT l->>'id' FROM jsonb_array_elements(p_rows)x CROSS JOIN LATERAL jsonb_array_elements(coalesce(x->'lots','[]'))l WHERE l->>'id' IS NOT NULL GROUP BY l->>'id' HAVING count(*)>1) THEN RAISE EXCEPTION 'INVENTORY_COUNT_DUPLICATE_LOT'; END IF;
 -- Existing available lots are retained by their ID. Counts cannot silently
 -- relabel or erase received-lot ancestry.
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x CROSS JOIN LATERAL jsonb_array_elements(coalesce(x->'lots','[]'))l
 LEFT JOIN inventory_lots old_lot ON old_lot.id=nullif(l->>'id','')::uuid
 WHERE l->>'id' IS NOT NULL AND (old_lot.id IS NULL OR old_lot.ingredient_id<>(x->>'inventory_item_id')::uuid OR old_lot.state<>'available'
 OR (old_lot.location_id,old_lot.supplier_lot_code,old_lot.expiry_date) IS DISTINCT FROM ((l->>'location_id')::uuid,nullif(btrim(l->>'code'),''),nullif(l->>'expiry_date','')::date))) THEN RAISE EXCEPTION 'INVENTORY_COUNT_LOT_IDENTITY_CHANGED'; END IF;
 SELECT jsonb_agg(x||jsonb_build_object('was_tracked',coalesce((x->>'inventory_item_id')::uuid=ANY(was_tracked),false),
 'previous_lots',coalesce(prior.rows,'[]')) ORDER BY x->>'inventory_item_id') INTO rows_data
 FROM jsonb_array_elements(p_rows)x LEFT JOIN (SELECT ingredient_id,jsonb_agg(to_jsonb(l) ORDER BY id) rows FROM inventory_lots l WHERE ingredient_id=ANY(ids) AND state='available' AND quantity_base>0 GROUP BY ingredient_id)prior ON prior.ingredient_id=(x->>'inventory_item_id')::uuid;
 INSERT INTO inventory_lot_counts VALUES(p_id,p_store,p_employee,jsonb_build_object('id',worker.id,'name',worker.full_name,'number',worker.employee_number),rows_data,btrim(p_reason),input_hash,auth.uid(),clock_timestamp()) RETURNING * INTO previous;
 INSERT INTO inventory_lot_count_rows(count_id,ingredient_id,data) SELECT p_id,(x->>'inventory_item_id')::uuid,x FROM jsonb_array_elements(rows_data)x;
 INSERT INTO inventory_lot_tracking(ingredient_id,restaurant_id,opening_count_id) SELECT (x->>'inventory_item_id')::uuid,p_store,p_id FROM jsonb_array_elements(p_rows)x WHERE (x->>'track_lots')::boolean ON CONFLICT DO NOTHING;
 -- Count differences on existing lots; omitted IDs mean explicitly counted zero.
 WITH counted AS(SELECT (x->>'inventory_item_id')::uuid item_id,l FROM jsonb_array_elements(p_rows)x CROSS JOIN LATERAL jsonb_array_elements(coalesce(x->'lots','[]'))l WHERE l->>'id' IS NOT NULL)
 INSERT INTO inventory_lot_movements(lot_id,event_kind,event_id,quantity_base,created_by)
 SELECT old_lot.id,'count',p_id,coalesce((c.l->>'quantity_base')::numeric,0)-old_lot.quantity_base,auth.uid() FROM inventory_lots old_lot LEFT JOIN counted c ON c.l->>'id'=old_lot.id::text
 WHERE old_lot.ingredient_id=ANY(was_tracked) AND old_lot.state='available' AND old_lot.quantity_base<>coalesce((c.l->>'quantity_base')::numeric,0);
 UPDATE inventory_lots l SET quantity_base=l.quantity_base+m.quantity_base FROM inventory_lot_movements m WHERE m.event_kind='count' AND m.event_id=p_id AND m.lot_id=l.id;
 WITH counted AS(SELECT x,l.value lot,l.ordinality component FROM jsonb_array_elements(p_rows)x CROSS JOIN LATERAL jsonb_array_elements(coalesce(x->'lots','[]')) WITH ORDINALITY l(value,ordinality) WHERE (x->>'track_lots')::boolean AND l.value->>'id' IS NULL),
 created AS(INSERT INTO inventory_lots(id,restaurant_id,ingredient_id,location_id,supplier_lot_code,expiry_date,quantity_base,state,source_kind,source_id,source_component)
 SELECT md5(p_id::text||':'||(x->>'inventory_item_id')||':'||component)::uuid,p_store,(x->>'inventory_item_id')::uuid,(lot->>'location_id')::uuid,nullif(btrim(lot->>'code'),''),nullif(lot->>'expiry_date','')::date,(lot->>'quantity_base')::numeric,
 'available',CASE WHEN nullif(btrim(lot->>'code'),'') IS NULL THEN 'unknown_legacy' WHEN coalesce((x->>'inventory_item_id')::uuid=ANY(was_tracked),false) THEN 'count' ELSE 'opening_count' END,p_id,
 row_number() OVER(ORDER BY x->>'inventory_item_id',component)::integer FROM counted RETURNING *)
 INSERT INTO inventory_lot_movements(lot_id,event_kind,event_id,quantity_base,created_by) SELECT id,'count',p_id,quantity_base,auth.uid() FROM created;
 UPDATE inventory_items i SET current_stock=(x->>'actual_quantity_base')::numeric,quantity=(x->>'actual_quantity_base')::numeric,updated_at=clock_timestamp()
 FROM jsonb_array_elements(p_rows)x WHERE i.id=(x->>'inventory_item_id')::uuid;
 INSERT INTO inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,reference_id,note,created_by,performed_by_employee_id,stock_before,stock_after,effective_at,effective_date)
 SELECT p_store,(x->>'inventory_item_id')::uuid,'adjust',(x->>'actual_quantity_base')::numeric-(x->>'expected_stock')::numeric,'inventory_lot_count',p_id,btrim(p_reason),auth.uid(),p_employee,(x->>'expected_stock')::numeric,(x->>'actual_quantity_base')::numeric,(x->>'counted_at')::timestamptz,((x->>'counted_at')::timestamptz AT TIME ZONE 'Asia/Ho_Chi_Minh')::date FROM jsonb_array_elements(p_rows)x;
 PERFORM inventory_queue_lot_reconciliation_v1(ids);
 RETURN to_jsonb(previous);
END $$;
REVOKE ALL ON FUNCTION public.admin_record_inventory_lot_count_v1(uuid,uuid,uuid,jsonb,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_record_inventory_lot_count_v1(uuid,uuid,uuid,jsonb,text) TO authenticated;
COMMIT;
