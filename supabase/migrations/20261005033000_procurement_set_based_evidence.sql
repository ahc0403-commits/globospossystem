BEGIN;
CREATE OR REPLACE FUNCTION public.procurement_demand_evidence(p_store_id uuid,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;fresh_hours integer;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 SELECT COALESCE(stock_freshness_hours,24) INTO fresh_hours FROM public.procurement_store_policies WHERE restaurant_id=p_store_id;
 RETURN (WITH products AS MATERIALIZED(SELECT * FROM public.inventory_products WHERE restaurant_id=p_store_id AND is_active AND is_orderable AND receipt_classification='stock'),
 mappings AS(SELECT inventory_item_id,count(*) count FROM products GROUP BY inventory_item_id),
 usage AS(SELECT tx.ingredient_id,sum(CASE WHEN tx.transaction_type='deduct' THEN abs(tx.quantity_g) ELSE 0 END) actual_usage,
   sum(CASE WHEN tx.transaction_type='waste' THEN abs(tx.quantity_g) ELSE 0 END) waste_usage,count(DISTINCT (tx.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date) observed_days
   FROM public.inventory_transactions tx WHERE tx.restaurant_id=p_store_id AND tx.transaction_type IN ('deduct','waste') AND COALESCE(tx.reference_type,'')<>'inventory_supplier_return'
   AND tx.created_at>=((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date-28)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
   AND tx.created_at<(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' GROUP BY tx.ingredient_id),
 accepted AS(SELECT l.purchase_order_line_id,sum(l.accepted_quantity_base) qty FROM public.inventory_receipt_lines l JOIN public.inventory_receipts r ON r.id=l.receipt_id
   WHERE r.restaurant_id=p_store_id AND r.status='confirmed' GROUP BY l.purchase_order_line_id),
 inbound AS(SELECT l.product_id,sum(greatest(0,l.ordered_quantity_base-l.cancelled_quantity_base-COALESCE(a.qty,0))) qty FROM public.inventory_purchase_order_lines l
   JOIN public.inventory_purchase_orders po ON po.id=l.purchase_order_id LEFT JOIN accepted a ON a.purchase_order_line_id=l.id
   WHERE po.restaurant_id=p_store_id AND po.status IN ('office_approved','ordered','partially_received') GROUP BY l.product_id),
 allocated AS(SELECT a.request_line_id,sum(a.quantity_base) qty FROM public.procurement_allocations a JOIN public.inventory_purchase_request_lines l ON l.id=a.request_line_id
   JOIN public.inventory_purchase_requests r ON r.id=l.request_id WHERE r.restaurant_id=p_store_id GROUP BY a.request_line_id),
 requested AS(SELECT l.product_id,sum(greatest(0,l.quantity_base-COALESCE(a.qty,0))) qty FROM public.inventory_purchase_request_lines l
   JOIN public.inventory_purchase_requests r ON r.id=l.request_id LEFT JOIN allocated a ON a.request_line_id=l.id WHERE r.restaurant_id=p_store_id AND l.active AND r.status NOT IN ('cancelled','allocated') GROUP BY l.product_id),
 history AS(SELECT l.product_id,max(r.received_at) last_received,avg(l.accepted_quantity_base) average_qty,
   (array_agg(l.actual_unit_price ORDER BY r.received_at DESC,r.id DESC,l.id DESC))[1] last_price FROM public.inventory_receipt_lines l JOIN public.inventory_receipts r ON r.id=l.receipt_id
   WHERE r.restaurant_id=p_store_id AND r.status='confirmed' AND l.accepted_quantity_base>0 GROUP BY l.product_id)
 SELECT COALESCE(jsonb_agg(jsonb_build_object('product_id',p.id,'product_name',p.name,'base_unit',p.base_unit,'stock_unit',p.stock_unit,'stock_conversion',p.base_unit_factor,
   'current_stock_base',it.current_stock,'stock_updated_at',it.updated_at,'minimum_stock_base',it.reorder_point,'mapping_count',m.count,
   'stock_fresh',it.updated_at>=now()-make_interval(hours=>COALESCE(fresh_hours,24)),
   'actual_daily_usage_base',COALESCE(u.actual_usage,0)/28,'waste_daily_base',COALESCE(u.waste_usage,0)/28,'observed_usage_days',COALESCE(u.observed_days,0),
   'usage_window_days',28,'usage_as_of',(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date-1,'inbound_quantity_base',COALESCE(i.qty,0),'pending_request_quantity_base',COALESCE(r.qty,0),
   'last_received_at',h.last_received,'average_received_quantity_base',h.average_qty,'recent_unit_price',CASE WHEN COALESCE((actor->>'can_view_prices')::boolean,false) THEN h.last_price ELSE NULL END) ORDER BY p.name,p.id),'[]')
 FROM products p LEFT JOIN public.inventory_items it ON it.id=p.inventory_item_id AND it.restaurant_id=p_store_id
 LEFT JOIN mappings m ON m.inventory_item_id=p.inventory_item_id LEFT JOIN usage u ON u.ingredient_id=p.inventory_item_id LEFT JOIN inbound i ON i.product_id=p.id
 LEFT JOIN requested r ON r.product_id=p.id LEFT JOIN history h ON h.product_id=p.id);
END $$;
CREATE OR REPLACE FUNCTION public.procurement_supplier_evidence(p_store_id uuid,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;result jsonb;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 WITH suppliers AS(SELECT DISTINCT s.id,s.supplier_name FROM public.inventory_suppliers s JOIN public.inventory_supplier_items si ON si.supplier_id=s.id JOIN public.inventory_products p ON p.id=si.product_id WHERE p.restaurant_id=p_store_id),
 orders AS(SELECT supplier_id,count(*) count FROM public.inventory_purchase_orders WHERE restaurant_id=p_store_id AND created_at>=now()-interval '90 days' GROUP BY supplier_id),
 receipts AS(SELECT r.supplier_id,count(*) count,count(*) FILTER(WHERE (r.received_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date<=po.requested_delivery_date) on_time
   FROM public.inventory_receipts r JOIN public.inventory_purchase_orders po ON po.id=r.purchase_order_id WHERE r.restaurant_id=p_store_id AND r.status='confirmed' AND r.received_at>=now()-interval '90 days' GROUP BY r.supplier_id),
 issues AS(SELECT po.supplier_id,count(*) FILTER(WHERE i.status='open') count,avg(extract(epoch FROM(i.resolved_at-i.created_at))/3600) FILTER(WHERE i.resolved_at>=now()-interval '90 days') hours
   FROM public.inventory_receipt_issues i JOIN public.inventory_purchase_orders po ON po.id=i.purchase_order_id WHERE i.restaurant_id=p_store_id GROUP BY po.supplier_id)
 SELECT jsonb_build_object('supplier_performance',COALESCE(jsonb_agg(jsonb_build_object('supplier_id',s.id,'supplier_name',s.supplier_name,'order_count_90d',COALESCE(o.count,0),
   'confirmed_receipts_90d',COALESCE(r.count,0),'on_time_receipts_90d',COALESCE(r.on_time,0),'open_issues',COALESCE(i.count,0),'average_resolution_hours',i.hours) ORDER BY s.id),'[]'))
 INTO result FROM suppliers s LEFT JOIN orders o ON o.supplier_id=s.id LEFT JOIN receipts r ON r.supplier_id=s.id LEFT JOIN issues i ON i.supplier_id=s.id;
 RETURN result||jsonb_build_object('price_history',CASE WHEN COALESCE((actor->>'can_view_prices')::boolean,false) THEN COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM(
 SELECT h.*,p.name product_name,s.supplier_name FROM public.inventory_supplier_item_price_history h JOIN public.inventory_products p ON p.id=h.product_id JOIN public.inventory_suppliers s ON s.id=h.supplier_id
 WHERE h.restaurant_id=p_store_id ORDER BY h.created_at DESC,h.id LIMIT 100) x),'[]') ELSE '[]' END);
END $$;
-- One scoped RPC for the legacy multi-store list; the bridge supplies authorized POS scope IDs.
CREATE FUNCTION public.procurement_orders_batch(p_store_ids uuid[],p_status text DEFAULT NULL,p_before timestamptz DEFAULT NULL,p_before_id uuid DEFAULT NULL,p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' OR p_store_ids IS NULL OR cardinality(p_store_ids) NOT BETWEEN 1 AND 100 OR array_position(p_store_ids,NULL) IS NOT NULL THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 RETURN COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC,x.id DESC) FROM(
 SELECT po.id,po.purchase_order_no,po.restaurant_id,po.restaurant_id store_id,po.brand_id,po.supplier_id,s.supplier_name,po.status,po.workflow_version,po.requested_delivery_date,
 po.total_supply_amount,po.tax_amount,po.total_amount,po.office_reviewed_at,po.created_at,po.updated_at
 FROM public.inventory_purchase_orders po JOIN public.inventory_suppliers s ON s.id=po.supplier_id
 WHERE po.restaurant_id=ANY(p_store_ids) AND(p_status IS NULL OR po.status=p_status) AND(p_before IS NULL OR(po.created_at,po.id)<(p_before,p_before_id))
 ORDER BY po.created_at DESC,po.id DESC LIMIT greatest(1,least(200,p_limit))) x),'[]');
END $$;
REVOKE ALL ON FUNCTION public.procurement_orders_batch(uuid[],text,timestamptz,uuid,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.procurement_orders_batch(uuid[],text,timestamptz,uuid,integer) TO service_role;
CREATE FUNCTION public.procurement_snapshot_compat(p_snapshot jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE WHEN COALESCE(p_snapshot->'order'->'commercial_terms'->>'approval_policy_version','1')='1' THEN
   (p_snapshot-'channel_payments')||jsonb_build_object('lines',COALESCE((SELECT jsonb_agg(l-'receipt_classification_snapshot' ORDER BY l->>'id') FROM jsonb_array_elements(p_snapshot->'lines') l),'[]'),
     'receipts',COALESCE((SELECT jsonb_agg(r||jsonb_build_object('lines',COALESCE((SELECT jsonb_agg(l-'expected_quantity_base_snapshot' ORDER BY l->>'id') FROM jsonb_array_elements(r->'lines') l),'[]')) ORDER BY r->>'id') FROM jsonb_array_elements(p_snapshot->'receipts') r),'[]'))
 ELSE p_snapshot END
$$;
REVOKE ALL ON FUNCTION public.procurement_snapshot_compat(jsonb) FROM PUBLIC,anon,authenticated;
-- Read batches preaggregate each one-to-many relation before combining them.
CREATE FUNCTION public.procurement_snapshots_data(p_store_ids uuid[],p_order_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
BEGIN
 IF p_store_ids IS NULL OR p_order_ids IS NULL OR cardinality(p_store_ids) NOT BETWEEN 1 AND 100 OR cardinality(p_order_ids) NOT BETWEEN 1 AND 50 OR array_position(p_store_ids,NULL) IS NOT NULL OR array_position(p_order_ids,NULL) IS NOT NULL THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 IF EXISTS(SELECT 1 FROM unnest(p_order_ids) AS ids(order_id) LEFT JOIN public.inventory_purchase_orders po ON po.id=ids.order_id AND po.restaurant_id=ANY(p_store_ids) WHERE po.id IS NULL) THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 RETURN(WITH orders AS MATERIALIZED(SELECT * FROM public.inventory_purchase_orders WHERE id=ANY(p_order_ids) AND restaurant_id=ANY(p_store_ids)),
 returns AS MATERIALIZED(SELECT r.* FROM public.inventory_supplier_returns r JOIN orders po ON po.id=r.purchase_order_id),
 returned AS(SELECT receipt_line_id,sum(quantity_base) qty FROM returns GROUP BY receipt_line_id),
 po_lines AS(SELECT l.purchase_order_id,jsonb_agg(to_jsonb(l)||jsonb_build_object('product_name',p.name) ORDER BY l.id) rows FROM public.inventory_purchase_order_lines l JOIN orders po ON po.id=l.purchase_order_id JOIN public.inventory_products p ON p.id=l.product_id GROUP BY l.purchase_order_id),
 receipt_lines AS(SELECT l.receipt_id,jsonb_agg(to_jsonb(l)||jsonb_build_object('returned_quantity_base',COALESCE(t.qty,0)) ORDER BY l.id) rows FROM public.inventory_receipt_lines l
 JOIN public.inventory_receipts r ON r.id=l.receipt_id JOIN orders po ON po.id=r.purchase_order_id LEFT JOIN returned t ON t.receipt_line_id=l.id WHERE r.status='confirmed' GROUP BY l.receipt_id),
 receipts AS(SELECT r.purchase_order_id,jsonb_agg(to_jsonb(r)||jsonb_build_object('lines',COALESCE(l.rows,'[]')) ORDER BY r.id) rows FROM public.inventory_receipts r JOIN orders po ON po.id=r.purchase_order_id LEFT JOIN receipt_lines l ON l.receipt_id=r.id WHERE r.status='confirmed' GROUP BY r.purchase_order_id),
 payments AS(SELECT p.purchase_order_id,jsonb_agg(to_jsonb(p) ORDER BY p.id) rows FROM public.procurement_channel_payments p JOIN orders po ON po.id=p.purchase_order_id GROUP BY p.purchase_order_id),
 return_rows AS(SELECT purchase_order_id,jsonb_agg(to_jsonb(r) ORDER BY r.id) rows FROM returns r GROUP BY purchase_order_id)
 SELECT COALESCE(jsonb_agg(public.procurement_snapshot_compat(jsonb_build_object('contract_version',2,'order',to_jsonb(po),'lines',COALESCE(l.rows,'[]'),'receipts',COALESCE(r.rows,'[]'),'returns',COALESCE(t.rows,'[]'),'channel_payments',COALESCE(cp.rows,'[]'))) ORDER BY po.id),'[]')
 FROM orders po LEFT JOIN po_lines l ON l.purchase_order_id=po.id LEFT JOIN receipts r ON r.purchase_order_id=po.id LEFT JOIN return_rows t ON t.purchase_order_id=po.id LEFT JOIN payments cp ON cp.purchase_order_id=po.id);
END $$;
REVOKE ALL ON FUNCTION public.procurement_snapshots_data(uuid[],uuid[]) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.procurement_snapshots_batch(p_store_ids uuid[],p_order_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 RETURN public.procurement_snapshots_data(p_store_ids,p_order_ids);
END $$;
REVOKE ALL ON FUNCTION public.procurement_snapshots_batch(uuid[],uuid[]) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.procurement_snapshots_batch(uuid[],uuid[]) TO service_role;
CREATE OR REPLACE FUNCTION public.procurement_order_snapshot(p_store_id uuid,p_order_id uuid,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;result jsonb;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 IF NOT COALESCE((actor->>'can_view_prices')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_PRICES_FORBIDDEN'; END IF;
 result:=public.procurement_snapshots_data(ARRAY[p_store_id],ARRAY[p_order_id]);
 RETURN result->0;
END $$;
COMMIT;
