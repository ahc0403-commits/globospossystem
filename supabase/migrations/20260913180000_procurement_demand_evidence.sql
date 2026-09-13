BEGIN;
CREATE FUNCTION public.procurement_demand_evidence(p_store_id uuid,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;fresh_hours integer;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 SELECT COALESCE(stock_freshness_hours,24) INTO fresh_hours FROM public.procurement_store_policies WHERE restaurant_id=p_store_id;
 RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
   'product_id',p.id,'product_name',p.name,'base_unit',p.base_unit,'stock_unit',p.stock_unit,'stock_conversion',p.base_unit_factor,
   'current_stock_base',it.current_stock,'stock_updated_at',it.updated_at,'minimum_stock_base',it.reorder_point,
   'mapping_count',(SELECT count(*) FROM public.inventory_products m WHERE m.restaurant_id=p_store_id AND m.inventory_item_id=p.inventory_item_id AND m.is_active AND m.is_orderable),
   'stock_fresh',it.updated_at>=now()-make_interval(hours=>COALESCE(fresh_hours,24)),
   'actual_daily_usage_base',COALESCE(usage.actual_usage,0)/28,'waste_daily_base',COALESCE(usage.waste_usage,0)/28,
   'observed_usage_days',COALESCE(usage.observed_days,0),'usage_window_days',28,'usage_as_of',(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date-1,
   'inbound_quantity_base',COALESCE(inbound.qty,0),'pending_request_quantity_base',COALESCE(requested.qty,0),
   'last_received_at',history.last_received,'average_received_quantity_base',history.average_qty,
   'recent_unit_price',CASE WHEN COALESCE((actor->>'can_view_prices')::boolean,false) THEN history.last_price ELSE NULL END
 ) ORDER BY p.name,p.id)
 FROM public.inventory_products p LEFT JOIN public.inventory_items it ON it.id=p.inventory_item_id AND it.restaurant_id=p_store_id
 LEFT JOIN LATERAL (
   SELECT sum(CASE WHEN tx.transaction_type='deduct' THEN abs(tx.quantity_g) ELSE 0 END) actual_usage,
     sum(CASE WHEN tx.transaction_type='waste' THEN abs(tx.quantity_g) ELSE 0 END) waste_usage,
     count(DISTINCT (tx.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date) observed_days
   FROM public.inventory_transactions tx WHERE tx.restaurant_id=p_store_id AND tx.ingredient_id=p.inventory_item_id
     AND tx.transaction_type IN ('deduct','waste') AND COALESCE(tx.reference_type,'')<>'inventory_supplier_return'
     AND (tx.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date BETWEEN (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date-28 AND (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date-1
 ) usage ON true
 LEFT JOIN LATERAL (
   SELECT sum(greatest(0,l.ordered_quantity_base-l.cancelled_quantity_base-COALESCE((SELECT sum(rl.accepted_quantity_base) FROM public.inventory_receipt_lines rl JOIN public.inventory_receipts r ON r.id=rl.receipt_id WHERE rl.purchase_order_line_id=l.id AND r.status='confirmed'),0))) qty
   FROM public.inventory_purchase_order_lines l JOIN public.inventory_purchase_orders po ON po.id=l.purchase_order_id
   WHERE po.restaurant_id=p_store_id AND l.product_id=p.id AND po.status IN ('office_approved','ordered','partially_received')
 ) inbound ON true
 LEFT JOIN LATERAL (
   SELECT sum(greatest(0,l.quantity_base-COALESCE((SELECT sum(a.quantity_base) FROM public.procurement_allocations a WHERE a.request_line_id=l.id),0))) qty
   FROM public.inventory_purchase_request_lines l JOIN public.inventory_purchase_requests r ON r.id=l.request_id
   WHERE r.restaurant_id=p_store_id AND l.product_id=p.id AND l.active AND r.status NOT IN ('cancelled','allocated')
 ) requested ON true
 LEFT JOIN LATERAL (
   SELECT max(r.received_at) last_received,avg(l.accepted_quantity_base) average_qty,
     (array_agg(l.actual_unit_price ORDER BY r.received_at DESC,r.id DESC))[1] last_price
   FROM public.inventory_receipt_lines l JOIN public.inventory_receipts r ON r.id=l.receipt_id
   WHERE r.restaurant_id=p_store_id AND l.product_id=p.id AND r.status='confirmed' AND l.accepted_quantity_base>0
 ) history ON true
 WHERE p.restaurant_id=p_store_id AND p.is_active AND p.is_orderable),'[]');
END $$;
REVOKE ALL ON FUNCTION public.procurement_demand_evidence(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_demand_evidence(uuid,jsonb) TO authenticated,service_role;
COMMIT;
