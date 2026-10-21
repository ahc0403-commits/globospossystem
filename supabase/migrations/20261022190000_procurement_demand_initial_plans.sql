-- Initial quantities require an owner's evidence. Demand facts are bounded,
-- distinguish held stock and exclude transferred/reserved inbound double counts.
-- production-gate: self-verifying
BEGIN;
CREATE TABLE public.procurement_initial_plans(
 id uuid PRIMARY KEY,restaurant_id uuid NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
 payload_hash text NOT NULL,reason text NOT NULL,actor_id uuid NOT NULL,approved_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE public.procurement_initial_plan_lines(
 plan_id uuid NOT NULL REFERENCES procurement_initial_plans(id) ON DELETE CASCADE,restaurant_id uuid NOT NULL REFERENCES restaurants(id) ON DELETE CASCADE,
 product_id uuid NOT NULL REFERENCES inventory_products(id) ON DELETE CASCADE,quantity_base numeric(18,3) NOT NULL CHECK(quantity_base>=0),base_unit text NOT NULL,
 valid_until date NOT NULL,approved_at timestamptz NOT NULL DEFAULT clock_timestamp(),PRIMARY KEY(plan_id,product_id)
);
CREATE INDEX procurement_initial_plan_latest ON public.procurement_initial_plan_lines(restaurant_id,product_id,approved_at DESC,plan_id DESC);
ALTER TABLE public.procurement_initial_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.procurement_initial_plan_lines ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.procurement_initial_plans,public.procurement_initial_plan_lines FROM PUBLIC,anon,authenticated;
CREATE TRIGGER procurement_initial_plans_immutable BEFORE UPDATE ON public.procurement_initial_plans FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE TRIGGER procurement_initial_plan_lines_immutable BEFORE UPDATE ON public.procurement_initial_plan_lines FOR EACH ROW EXECUTE FUNCTION public.store_operating_immutable_v1();
CREATE FUNCTION public.admin_approve_initial_purchase_plan_v1(p_id uuid,p_store uuid,p_rows jsonb,p_valid_until date,p_reason text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE hash text; prior procurement_initial_plans;
BEGIN
 PERFORM require_brand_admin_v1();
 IF p_id IS NULL OR jsonb_typeof(p_rows) IS DISTINCT FROM 'array' OR jsonb_array_length(p_rows) NOT BETWEEN 1 AND 100 OR octet_length(p_rows::text)>65536 OR p_valid_until IS NULL OR length(btrim(coalesce(p_reason,''))) NOT BETWEEN 5 AND 1000 THEN RAISE EXCEPTION 'INITIAL_PLAN_INVALID'; END IF;
 hash:=md5(jsonb_build_object('actor',auth.uid(),'store',p_store,'rows',p_rows,'until',p_valid_until,'reason',btrim(p_reason))::text);
 PERFORM pg_advisory_xact_lock(hashtextextended('initial-plan:'||p_id,0));
 SELECT * INTO prior FROM procurement_initial_plans WHERE id=p_id;
 IF FOUND THEN IF prior.payload_hash<>hash THEN RAISE EXCEPTION 'REQUEST_CONFLICT'; END IF; RETURN prior.id; END IF;
 IF p_valid_until<(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date OR p_valid_until>(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date+365 THEN RAISE EXCEPTION 'INITIAL_PLAN_EXPIRY_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x LEFT JOIN inventory_products p ON p.id=(x->>'product_id')::uuid AND p.restaurant_id=p_store AND p.is_active AND p.is_orderable AND p.receipt_classification='stock'
 WHERE p.id IS NULL OR x->>'base_unit' IS DISTINCT FROM p.base_unit OR jsonb_typeof(x->'quantity_base') IS DISTINCT FROM 'number' OR (x->>'quantity_base')::numeric<0 OR (x->>'quantity_base')::numeric<>round((x->>'quantity_base')::numeric,3))
 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_rows)x GROUP BY x->>'product_id' HAVING count(*)>1) THEN RAISE EXCEPTION 'INITIAL_PLAN_ITEM_INVALID'; END IF;
 INSERT INTO procurement_initial_plans VALUES(p_id,p_store,hash,btrim(p_reason),auth.uid(),clock_timestamp());
 INSERT INTO procurement_initial_plan_lines(plan_id,restaurant_id,product_id,quantity_base,base_unit,valid_until) SELECT p_id,p_store,(x->>'product_id')::uuid,(x->>'quantity_base')::numeric,x->>'base_unit',p_valid_until FROM jsonb_array_elements(p_rows)x;
 RETURN p_id;
END $$;
CREATE OR REPLACE FUNCTION public.procurement_demand_evidence_v2(p_store_id uuid,p_office_actor jsonb DEFAULT NULL,p_products uuid[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;fresh_hours integer;
BEGIN
 IF p_products IS NOT NULL AND cardinality(p_products)>100 THEN RAISE EXCEPTION 'DEMAND_PAGE_LIMIT'; END IF;
 IF p_products IS NULL AND (SELECT count(*) FROM inventory_products WHERE restaurant_id=p_store_id AND is_active AND is_orderable)>2000 THEN RAISE EXCEPTION 'DEMAND_USE_PAGED_READ'; END IF;
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 SELECT COALESCE(stock_freshness_hours,24) INTO fresh_hours FROM public.procurement_store_policies WHERE restaurant_id=p_store_id;
 RETURN (WITH products AS MATERIALIZED(SELECT * FROM public.inventory_products WHERE restaurant_id=p_store_id AND is_active AND is_orderable AND receipt_classification='stock' AND (p_products IS NULL OR id=ANY(p_products))),
 mappings AS(SELECT inventory_item_id,count(*) count FROM products GROUP BY inventory_item_id),
 usage AS(SELECT tx.ingredient_id,sum(CASE WHEN tx.transaction_type='deduct' THEN abs(tx.quantity_g) ELSE 0 END) actual_usage,
   sum(CASE WHEN tx.transaction_type='waste' THEN abs(tx.quantity_g) ELSE 0 END) waste_usage,count(DISTINCT (tx.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date) observed_days
   FROM public.inventory_transactions tx WHERE tx.restaurant_id=p_store_id AND tx.transaction_type IN ('deduct','waste') AND COALESCE(tx.reference_type,'')<>'inventory_supplier_return'
   AND tx.ingredient_id IN(SELECT inventory_item_id FROM products) AND tx.created_at>=((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date-28)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
   AND tx.created_at<(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' GROUP BY tx.ingredient_id),
 open_lines AS MATERIALIZED(SELECT l.* FROM inventory_purchase_order_lines l JOIN inventory_purchase_orders po ON po.id=l.purchase_order_id WHERE po.restaurant_id=p_store_id AND po.status IN('office_approved','ordered','partially_received') AND l.product_id IN(SELECT id FROM products)),
 held AS(SELECT order_line_id purchase_order_line_id,quantity_base qty FROM inventory_held_by_order_line_v1(ARRAY(SELECT id FROM open_lines))),
 reserved AS(SELECT s.original_order_line_id,sum(s.quantity_base) qty FROM procurement_shortage_allocations s WHERE s.status='reserved' AND s.original_order_line_id IN(SELECT id FROM open_lines) GROUP BY s.original_order_line_id),
 accepted AS(SELECT l.purchase_order_line_id,sum(l.accepted_quantity_base) qty FROM public.inventory_receipt_lines l JOIN public.inventory_receipts r ON r.id=l.receipt_id
   WHERE l.purchase_order_line_id IN(SELECT id FROM open_lines) AND r.status='confirmed' GROUP BY l.purchase_order_line_id),
 inbound AS(SELECT l.product_id,sum(greatest(0,l.ordered_quantity_base-l.cancelled_quantity_base-COALESCE(a.qty,0)-coalesce(h.qty,0)-coalesce(s.qty,0))) qty FROM open_lines l
   JOIN public.inventory_purchase_orders po ON po.id=l.purchase_order_id LEFT JOIN accepted a ON a.purchase_order_line_id=l.id LEFT JOIN held h ON h.purchase_order_line_id=l.id LEFT JOIN reserved s ON s.original_order_line_id=l.id
   WHERE po.restaurant_id=p_store_id AND po.status IN ('office_approved','ordered','partially_received') GROUP BY l.product_id),
 allocated AS(SELECT a.request_line_id,sum(a.quantity_base) qty FROM public.procurement_allocations a JOIN public.inventory_purchase_request_lines l ON l.id=a.request_line_id
   JOIN public.inventory_purchase_requests r ON r.id=l.request_id WHERE r.restaurant_id=p_store_id AND l.product_id IN(SELECT id FROM products) GROUP BY a.request_line_id),
 requested AS(SELECT l.product_id,sum(greatest(0,l.quantity_base-COALESCE(a.qty,0))) qty FROM public.inventory_purchase_request_lines l
   JOIN public.inventory_purchase_requests r ON r.id=l.request_id LEFT JOIN allocated a ON a.request_line_id=l.id WHERE r.restaurant_id=p_store_id AND l.product_id IN(SELECT id FROM products) AND l.active AND r.status NOT IN ('cancelled','allocated') GROUP BY l.product_id),
 history AS(SELECT l.product_id,max(r.received_at) last_received,avg(l.accepted_quantity_base) average_qty,
   (array_agg(l.actual_unit_price ORDER BY r.received_at DESC,r.id DESC,l.id DESC))[1] last_price FROM public.inventory_receipt_lines l JOIN public.inventory_receipts r ON r.id=l.receipt_id
   WHERE r.restaurant_id=p_store_id AND r.status='confirmed' AND l.accepted_quantity_base>0 AND l.product_id IN(SELECT id FROM products) AND r.received_at>=now()-interval '90 days' AND NOT EXISTS(SELECT 1 FROM inventory_lot_receipt_origins origin WHERE origin.receipt_id=r.id) GROUP BY l.product_id),
 lot_stock AS(SELECT ingredient_id,sum(quantity_base) FILTER(WHERE state='held') held,sum(quantity_base) FILTER(WHERE state='available' AND (expiry_date IS NULL OR expiry_date>=(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date)) usable FROM inventory_lots WHERE restaurant_id=p_store_id AND ingredient_id IN(SELECT inventory_item_id FROM products) GROUP BY ingredient_id),
 plans AS(SELECT DISTINCT ON(product_id) * FROM procurement_initial_plan_lines WHERE restaurant_id=p_store_id AND product_id IN(SELECT id FROM products) ORDER BY product_id,approved_at DESC,plan_id DESC),
 suppliers AS(SELECT s.product_id,jsonb_agg(jsonb_build_object('supplier_id',s.supplier_id,'lead_time_days',s.lead_time_days,'min_order_quantity',s.min_order_quantity,'order_unit_quantity_base',s.order_unit_quantity_base) ORDER BY s.id) terms FROM inventory_supplier_items s WHERE s.product_id IN(SELECT id FROM products) AND s.is_active GROUP BY s.product_id)
 SELECT COALESCE(jsonb_agg(jsonb_build_object('product_id',p.id,'product_name',p.name,'base_unit',p.base_unit,'stock_unit',p.stock_unit,'stock_conversion',p.base_unit_factor,
   'current_stock_base',it.current_stock,'stock_updated_at',it.updated_at,'minimum_stock_base',it.reorder_point,'mapping_count',m.count,
   'stock_fresh',it.updated_at>=now()-make_interval(hours=>COALESCE(fresh_hours,24)),
   'actual_daily_usage_base',COALESCE(u.actual_usage,0)/28,'waste_daily_base',COALESCE(u.waste_usage,0)/28,'observed_usage_days',COALESCE(u.observed_days,0),
   'usage_window_days',28,'evidence_version','usage28d-v2','recommendation_formula_version','weighted4-7-v1','recommendation_formula','max(0,target_days*(avg4*0.7+avg7*0.3)-current_stock)','history_window_days',90,'held_quantity_base',coalesce(ls.held,0),'usable_stock_base',CASE WHEN tracking.ingredient_id IS NOT NULL THEN coalesce(ls.usable,0) ELSE it.current_stock END,'supplier_terms',coalesce(supplier.terms,'[]'),'initial_plan',CASE WHEN plan.valid_until>=(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AND plan.base_unit=p.base_unit THEN to_jsonb(plan) END,'needs_initial_plan',coalesce(u.observed_days,0)=0 AND (plan.plan_id IS NULL OR plan.valid_until<(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date OR plan.base_unit<>p.base_unit),'can_approve_initial_plan',is_super_admin(),'usage_as_of',(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date-1,'inbound_quantity_base',COALESCE(i.qty,0),'pending_request_quantity_base',COALESCE(r.qty,0),
   'last_received_at',h.last_received,'average_received_quantity_base',h.average_qty,'recent_unit_price',CASE WHEN COALESCE((actor->>'can_view_prices')::boolean,false) THEN h.last_price ELSE NULL END) ORDER BY p.name,p.id),'[]')
 FROM products p LEFT JOIN public.inventory_items it ON it.id=p.inventory_item_id AND it.restaurant_id=p_store_id
 LEFT JOIN mappings m ON m.inventory_item_id=p.inventory_item_id LEFT JOIN usage u ON u.ingredient_id=p.inventory_item_id LEFT JOIN inbound i ON i.product_id=p.id
 LEFT JOIN requested r ON r.product_id=p.id LEFT JOIN history h ON h.product_id=p.id LEFT JOIN lot_stock ls ON ls.ingredient_id=p.inventory_item_id LEFT JOIN inventory_lot_tracking tracking ON tracking.ingredient_id=p.inventory_item_id LEFT JOIN plans plan ON plan.product_id=p.id LEFT JOIN suppliers supplier ON supplier.product_id=p.id);
END $$;
CREATE OR REPLACE FUNCTION public.procurement_demand_evidence(p_store_id uuid,p_office_actor jsonb DEFAULT NULL) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$ SELECT procurement_demand_evidence_v2(p_store_id,p_office_actor,NULL); $$;
CREATE FUNCTION public.procurement_demand_page_v1(p_store_id uuid,p_after uuid DEFAULT NULL,p_office_actor jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE ids uuid[]; next_id uuid;
BEGIN
 PERFORM procurement_actor(p_store_id,p_office_actor);
 SELECT array_agg(id ORDER BY id) INTO ids FROM(SELECT id FROM inventory_products WHERE restaurant_id=p_store_id AND is_active AND is_orderable AND receipt_classification='stock' AND (p_after IS NULL OR id>p_after) ORDER BY id LIMIT 51)p;
 IF cardinality(ids)>50 THEN next_id:=ids[50]; END IF;
 RETURN jsonb_build_object('demand',procurement_demand_evidence_v2(p_store_id,p_office_actor,coalesce(ids[1:50],'{}')),'demand_next_cursor',next_id);
END $$;
DO $$ DECLARE d text; BEGIN
 d:=pg_get_functiondef('public.procurement_workspace_page_core(uuid,jsonb,jsonb)'::regprocedure);
 IF position('jsonb_build_object(''demand'',public.procurement_demand_evidence(p_store_id,p_office_actor))' IN d)=0 THEN RAISE EXCEPTION 'DEMAND_PAGE_PATCH_MISMATCH'; END IF;
 d:=replace(d,'jsonb_build_object(''demand'',public.procurement_demand_evidence(p_store_id,p_office_actor))','public.procurement_demand_page_v1(p_store_id,nullif(p_query->>''demand_after'','''')::uuid,p_office_actor)'); EXECUTE d;
 -- A release after reinspection is not another supplier delivery. Only receipts
 -- with a promised date enter the punctuality denominator.
 d:=pg_get_functiondef('public.procurement_supplier_evidence(uuid,jsonb)'::regprocedure);
 d:=replace(d,'count(*) count,count(*) FILTER(WHERE (r.received_at','count(*) count,count(*) FILTER(WHERE po.requested_delivery_date IS NOT NULL) scheduled,count(*) FILTER(WHERE (r.received_at');
 d:=replace(d,'AND r.received_at>=now()-interval ''90 days'' GROUP BY r.supplier_id','AND r.received_at>=now()-interval ''90 days'' AND NOT EXISTS(SELECT 1 FROM inventory_lot_receipt_origins origin WHERE origin.receipt_id=r.id) GROUP BY r.supplier_id');
 d:=replace(d, 'issues AS(', 'quality AS(SELECT r.supplier_id,count(*) inspected_lines,count(*) FILTER(WHERE l.rejected_quantity_base>0 OR l.held_quantity_base>0) nonconforming_lines FROM inventory_receipt_lines l JOIN inventory_receipts r ON r.id=l.receipt_id WHERE r.restaurant_id=p_store_id AND r.status=''confirmed'' AND r.received_at>=now()-interval ''90 days'' AND NOT EXISTS(SELECT 1 FROM inventory_lot_receipt_origins origin WHERE origin.receipt_id=r.id) GROUP BY r.supplier_id),issues AS(');
 d:=replace(d,'LEFT JOIN issues i ON i.supplier_id=s.id','LEFT JOIN issues i ON i.supplier_id=s.id LEFT JOIN quality q ON q.supplier_id=s.id');
 d:=replace(d,'''open_issues'',COALESCE(i.count,0)','''inspected_lines_90d'',coalesce(q.inspected_lines,0),''nonconforming_lines_90d'',coalesce(q.nonconforming_lines,0),''open_issues'',COALESCE(i.count,0)');
 d:=replace(d,'''on_time_receipts_90d'',COALESCE(r.on_time,0)', '''scheduled_receipts_90d'',COALESCE(r.scheduled,0),''metric_version'',''physical-deliveries-v2'',''on_time_receipts_90d'',COALESCE(r.on_time,0)'); EXECUTE d;
 -- Replace the older per-product supplier lookup with one ranked supplier set;
 -- retain its quantities and ordering choices for existing stores.
 d:=pg_get_functiondef('public.run_inventory_purchase_recommendation(uuid,numeric,date)'::regprocedure);
 d:=replace(d,'LEFT JOIN LATERAL (','LEFT JOIN (');
 d:=replace(d,E'SELECT\n      isi.supplier_id',E'SELECT DISTINCT ON(isi.product_id)\n      isi.product_id, isi.supplier_id');
 d:=replace(d,'WHERE isi.product_id = status.product_id','WHERE isi.product_id IN(SELECT id FROM inventory_products WHERE restaurant_id=p_store_id AND is_active)');
 d:=replace(d,'ORDER BY isi.is_preferred DESC, isi.updated_at DESC','ORDER BY isi.product_id, isi.is_preferred DESC, isi.updated_at DESC,isi.id');
 d:=replace(d,E'    LIMIT 1\n  ) supplier_pick ON TRUE',E'  ) supplier_pick ON supplier_pick.product_id=status.product_id'); EXECUTE d;
END $$;
REVOKE ALL ON FUNCTION public.procurement_demand_evidence_v2(uuid,jsonb,uuid[]),public.procurement_demand_page_v1(uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.admin_approve_initial_purchase_plan_v1(uuid,uuid,jsonb,date,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_approve_initial_purchase_plan_v1(uuid,uuid,jsonb,date,text) TO authenticated;
COMMIT;
