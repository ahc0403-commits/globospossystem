BEGIN;
CREATE FUNCTION public.procurement_supplier_evidence(p_store_id uuid,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 RETURN jsonb_build_object('supplier_performance',COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM (
 SELECT s.id supplier_id,s.supplier_name,
 (SELECT count(*) FROM public.inventory_purchase_orders po WHERE po.restaurant_id=p_store_id AND po.supplier_id=s.id AND po.created_at>=now()-interval '90 days') order_count_90d,
 (SELECT count(*) FROM public.inventory_receipts r WHERE r.restaurant_id=p_store_id AND r.supplier_id=s.id AND r.status='confirmed' AND r.received_at>=now()-interval '90 days') confirmed_receipts_90d,
 (SELECT count(*) FROM public.inventory_receipts r JOIN public.inventory_purchase_orders po ON po.id=r.purchase_order_id WHERE r.restaurant_id=p_store_id AND r.supplier_id=s.id AND r.status='confirmed' AND r.received_at>=now()-interval '90 days' AND (r.received_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date<=po.requested_delivery_date) on_time_receipts_90d,
 (SELECT count(*) FROM public.inventory_receipt_issues i JOIN public.inventory_purchase_orders po ON po.id=i.purchase_order_id WHERE i.restaurant_id=p_store_id AND po.supplier_id=s.id AND i.status='open') open_issues,
 (SELECT avg(extract(epoch FROM (i.resolved_at-i.created_at))/3600) FROM public.inventory_receipt_issues i JOIN public.inventory_purchase_orders po ON po.id=i.purchase_order_id WHERE i.restaurant_id=p_store_id AND po.supplier_id=s.id AND i.resolved_at>=now()-interval '90 days') average_resolution_hours
 FROM public.inventory_suppliers s WHERE EXISTS(SELECT 1 FROM public.inventory_supplier_items si JOIN public.inventory_products p ON p.id=si.product_id WHERE si.supplier_id=s.id AND p.restaurant_id=p_store_id)
 ) x),'[]'),
 'price_history',CASE WHEN COALESCE((actor->>'can_view_prices')::boolean,false) THEN COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM (
 SELECT h.*,p.name product_name,s.supplier_name FROM public.inventory_supplier_item_price_history h JOIN public.inventory_products p ON p.id=h.product_id JOIN public.inventory_suppliers s ON s.id=h.supplier_id
 WHERE h.restaurant_id=p_store_id ORDER BY h.created_at DESC,h.id LIMIT 100) x),'[]') ELSE '[]'::jsonb END);
END $$;
REVOKE ALL ON FUNCTION public.procurement_supplier_evidence(uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_supplier_evidence(uuid,jsonb) TO authenticated,service_role;
COMMIT;
