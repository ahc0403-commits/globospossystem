-- Bounded comparison of frozen criteria and the latest approved version.
-- production-gate: self-verifying
BEGIN;
CREATE FUNCTION public.admin_get_order_quality_review_v1(p_store uuid,p_order uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE ids uuid[];
BEGIN
 PERFORM require_brand_admin_v1();
 IF NOT EXISTS(SELECT 1 FROM inventory_purchase_orders WHERE id=p_order AND restaurant_id=p_store) THEN RAISE EXCEPTION 'PROCUREMENT_SCOPE_FORBIDDEN'; END IF;
 SELECT array_agg(id ORDER BY id) INTO ids FROM inventory_purchase_order_lines WHERE purchase_order_id=p_order;
 IF cardinality(ids)>200 THEN RAISE EXCEPTION 'QUALITY_ORDER_LINE_LIMIT'; END IF;
 RETURN coalesce((WITH latest AS(SELECT DISTINCT ON(product_id) id,product_id,revision,criteria,reason FROM procurement_quality_profiles WHERE restaurant_id=p_store AND product_id IN(SELECT product_id FROM inventory_purchase_order_lines WHERE id=ANY(ids)) ORDER BY product_id,revision DESC)
 SELECT jsonb_agg(jsonb_build_object('line_id',l.id,'product_name',p.name,'current',to_jsonb(q),'latest',to_jsonb(v)) ORDER BY l.id)
 FROM inventory_purchase_order_lines l JOIN inventory_products p ON p.id=l.product_id JOIN procurement_effective_quality_v1(ids)q ON q.order_line_id=l.id LEFT JOIN latest v ON v.product_id=l.product_id WHERE l.id=ANY(ids)),'[]');
END $$;
REVOKE ALL ON FUNCTION public.admin_get_order_quality_review_v1(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_get_order_quality_review_v1(uuid,uuid) TO authenticated;
COMMIT;
