-- Catalog reads are independent of receiving/PO creation capability.
-- production-gate: self-verifying
BEGIN;
CREATE OR REPLACE FUNCTION public.get_inventory_order_catalog(p_store_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE result jsonb; actor_role text:=public.inventory_purchase_actor_role();
BEGIN
  IF actor_role IS NULL OR actor_role NOT IN ('inventory_orderer','admin','store_admin','brand_admin','super_admin')
    OR NOT public.can_access_inventory_workflow(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;
  WITH order_history AS(SELECT po.supplier_id,pol.product_id,po.id,COALESCE(po.brand_approved_at,po.updated_at,po.created_at) order_at,sum(pol.ordered_quantity_base) quantity_base
    FROM public.inventory_purchase_orders po JOIN public.inventory_purchase_order_lines pol ON pol.purchase_order_id=po.id
    WHERE po.restaurant_id=p_store_id AND po.status IN ('ordered','partially_received','received','office_approved') AND COALESCE(po.brand_approved_at,po.updated_at,po.created_at)>=now()-interval '30 days'
    GROUP BY po.supplier_id,pol.product_id,po.id,COALESCE(po.brand_approved_at,po.updated_at,po.created_at)),
  recent AS(SELECT *,row_number() OVER(PARTITION BY supplier_id,product_id ORDER BY order_at DESC,id DESC) n FROM order_history),
  history AS(SELECT supplier_id,product_id,count(*)::integer sample_count,percentile_cont(0.5) WITHIN GROUP(ORDER BY quantity_base::double precision)::numeric usual_quantity_base FROM recent WHERE n<=20 GROUP BY supplier_id,product_id)
  SELECT jsonb_build_object(
    'suppliers', COALESCE((SELECT jsonb_agg(jsonb_build_object('id',s.id,'supplier_name',s.supplier_name,'payment_terms',s.payment_terms,'status',s.status) ORDER BY s.supplier_name)
      FROM public.inventory_suppliers s WHERE s.status='active' AND EXISTS (
        SELECT 1 FROM public.inventory_supplier_items i JOIN public.inventory_products p ON p.id=i.product_id
        WHERE i.supplier_id=s.id AND i.is_active AND p.restaurant_id=p_store_id
          AND p.is_active AND p.is_orderable)), '[]'::jsonb),
    'items', COALESCE((SELECT jsonb_agg(
      jsonb_build_object('id',i.id,'supplier_id',i.supplier_id,'product_id',i.product_id,
        'order_unit',i.order_unit,'order_unit_quantity_base',i.order_unit_quantity_base,
        'min_order_quantity',i.min_order_quantity,
        'allows_fractional_quantity',i.allows_fractional_quantity,
        'usual_order_quantity_unit',CASE WHEN history.sample_count >= 5 THEN
          round(history.usual_quantity_base / NULLIF(i.order_unit_quantity_base,0),3) END,
        'usual_order_sample_count',history.sample_count,
        'is_active',i.is_active,
        'product',jsonb_build_object('id',p.id,'name',p.name,'is_active',p.is_active,'is_orderable',p.is_orderable),
        'supplier',jsonb_build_object('supplier_name',s.supplier_name,'status',s.status))
      || CASE WHEN public.inventory_purchase_actor_role()='inventory_orderer' THEN '{}'::jsonb
         ELSE to_jsonb(i) END
      ORDER BY p.name,i.id)
      FROM public.inventory_supplier_items i JOIN public.inventory_products p ON p.id=i.product_id
      JOIN public.inventory_suppliers s ON s.id=i.supplier_id
      LEFT JOIN history ON history.supplier_id=i.supplier_id AND history.product_id=i.product_id
      WHERE p.restaurant_id=p_store_id AND p.is_active AND p.is_orderable AND i.is_active AND s.status='active'), '[]'::jsonb)
  ) INTO result;
  RETURN result||jsonb_build_object('procurement_policy',(SELECT to_jsonb(p) FROM public.procurement_store_policies p WHERE restaurant_id=p_store_id));
END $$;
REVOKE ALL ON FUNCTION public.get_inventory_order_catalog(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_order_catalog(uuid) TO authenticated;
DO $$ BEGIN
 IF has_function_privilege('anon','public.get_inventory_order_catalog(uuid)','EXECUTE')
 OR NOT has_function_privilege('authenticated','public.get_inventory_order_catalog(uuid)','EXECUTE')
 OR position('can_create_inventory_purchase_order' IN pg_get_functiondef('public.get_inventory_order_catalog(uuid)'::regprocedure))>0
 OR position('can_access_inventory_workflow' IN pg_get_functiondef('public.get_inventory_order_catalog(uuid)'::regprocedure))=0
 THEN RAISE EXCEPTION 'PROCUREMENT_CATALOG_ENTRY_CONTRACT_INVALID'; END IF;
END $$;
COMMIT;
