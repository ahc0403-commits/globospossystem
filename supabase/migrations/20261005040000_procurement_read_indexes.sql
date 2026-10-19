BEGIN;
-- The cross-store legacy/v2 batch cannot use the existing v2-only page index.
CREATE INDEX procurement_orders_all_workflows_page ON public.inventory_purchase_orders(restaurant_id,created_at DESC,id DESC);
CREATE INDEX procurement_receipt_lines_receipt ON public.inventory_receipt_lines(receipt_id,id);
CREATE OR REPLACE FUNCTION public.procurement_orders_batch(p_store_ids uuid[],p_status text DEFAULT NULL,p_before timestamptz DEFAULT NULL,p_before_id uuid DEFAULT NULL,p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
BEGIN
 IF auth.role() IS DISTINCT FROM 'service_role' OR p_store_ids IS NULL OR cardinality(p_store_ids) NOT BETWEEN 1 AND 100 OR array_position(p_store_ids,NULL) IS NOT NULL THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 RETURN(WITH page AS MATERIALIZED(
 SELECT * FROM public.inventory_purchase_orders po WHERE po.restaurant_id=ANY(p_store_ids) AND(cardinality(p_store_ids)<>1 OR po.restaurant_id=(p_store_ids)[1]) AND(p_status IS NULL OR po.status=p_status)
   AND(p_before IS NULL OR(po.created_at,po.id)<(p_before,p_before_id))
 ORDER BY po.created_at DESC,po.id DESC LIMIT greatest(1,least(200,p_limit)))
 SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC,x.id DESC),'[]') FROM(
 SELECT po.id,po.purchase_order_no,po.restaurant_id,po.restaurant_id store_id,po.brand_id,po.supplier_id,s.supplier_name,po.status,po.workflow_version,po.requested_delivery_date,
 po.total_supply_amount,po.tax_amount,po.total_amount,po.office_reviewed_at,po.created_at,po.updated_at FROM page po JOIN public.inventory_suppliers s ON s.id=po.supplier_id) x);
END $$;
COMMIT;
