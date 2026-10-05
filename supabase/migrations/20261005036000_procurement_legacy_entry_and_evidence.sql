BEGIN;
CREATE FUNCTION public.guard_procurement_legacy_creation()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
 IF NEW.workflow_version=1 AND EXISTS(SELECT 1 FROM public.procurement_store_policies WHERE restaurant_id=NEW.restaurant_id AND three_stage_required) THEN RAISE EXCEPTION 'PROCUREMENT_REQUEST_REQUIRED'; END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.guard_procurement_legacy_creation() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER procurement_legacy_creation_guard BEFORE INSERT ON public.inventory_purchase_orders FOR EACH ROW EXECUTE FUNCTION public.guard_procurement_legacy_creation();
CREATE OR REPLACE FUNCTION public.get_inventory_order_catalog(p_store_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE result jsonb;
BEGIN
  IF NOT public.can_create_inventory_purchase_order(p_store_id) THEN
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

CREATE FUNCTION public.procurement_receipt_evidence(p_store_id uuid,p_receipt_id uuid,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;result jsonb;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 SELECT jsonb_build_object('statement_storage_path',r.statement_storage_path,'photo_paths',COALESCE((SELECT jsonb_agg(path) FROM public.inventory_receipt_lines l CROSS JOIN LATERAL jsonb_array_elements(COALESCE(l.inspection->'photo_paths','[]')) path WHERE l.receipt_id=r.id),'[]')) INTO result FROM public.inventory_receipts r WHERE r.id=p_receipt_id AND r.restaurant_id=p_store_id;
 IF result IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.procurement_receipt_evidence(uuid,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_receipt_evidence(uuid,uuid,jsonb) TO authenticated,service_role;
CREATE FUNCTION public.procurement_issue_context(p_store_id uuid,p_issue_id uuid,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb;result jsonb;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_OFFICE_FORBIDDEN'; END IF;
 SELECT to_jsonb(i) INTO result FROM public.inventory_receipt_issues i WHERE id=p_issue_id AND restaurant_id=p_store_id;
 IF result IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.procurement_issue_context(uuid,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_issue_context(uuid,uuid,jsonb) TO authenticated,service_role;
COMMIT;
