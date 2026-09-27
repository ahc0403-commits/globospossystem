-- Search the full authorized order set before pagination. A page-local filter
-- would hide older orders from managers once the first 80 rows are loaded.
BEGIN;
CREATE FUNCTION public.search_inventory_workflow_orders(
  p_store_id uuid, p_statuses text[], p_mine_only boolean,
  p_offset integer, p_limit integer, p_search text
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE
  result jsonb;
  v_role text := public.inventory_purchase_actor_role();
  v_search text := lower(btrim(COALESCE(p_search, '')));
BEGIN
  IF v_role NOT IN ('admin','store_admin','brand_admin','super_admin',
                   'inventory_orderer','inventory_accounting') OR v_role IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;
  IF p_store_id IS NOT NULL AND NOT public.can_access_inventory_workflow(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;
  IF length(v_search) > 120 THEN RAISE EXCEPTION 'INVENTORY_SEARCH_TOO_LONG'; END IF;

  WITH scoped AS (
    SELECT po.* FROM public.inventory_purchase_orders po
    WHERE public.can_access_inventory_workflow(po.restaurant_id)
      AND (v_role <> 'inventory_accounting'
        OR po.status IN ('ordered','partially_received','received','office_approved'))
      AND (p_store_id IS NULL OR po.restaurant_id=p_store_id)
      AND (NOT COALESCE(p_mine_only,false) OR
        (po.status='submitted' AND v_role IN ('admin','store_admin','super_admin')) OR
        (po.status='store_approved' AND v_role IN ('brand_admin','super_admin')
          AND po.store_approved_by IS DISTINCT FROM auth.uid()))
  ), filtered AS (
    SELECT po.* FROM scoped po
    JOIN public.inventory_suppliers s ON s.id=po.supplier_id
    WHERE (p_statuses IS NULL OR po.status=ANY(p_statuses))
      AND (v_search='' OR strpos(lower(COALESCE(po.purchase_order_no,'')),v_search)>0
        OR strpos(lower(COALESCE(s.supplier_name,'')),v_search)>0
        OR EXISTS (
          SELECT 1 FROM public.inventory_purchase_order_lines l
          JOIN public.inventory_products p ON p.id=l.product_id
          WHERE l.purchase_order_id=po.id
            AND strpos(lower(COALESCE(p.name,'')),v_search)>0))
  ), page AS (
    SELECT * FROM filtered ORDER BY
      CASE WHEN status IN ('draft','submitted','store_approved','office_returned') THEN 0 ELSE 1 END,
      CASE WHEN status IN ('draft','submitted','store_approved','office_returned')
        THEN COALESCE(submitted_at,created_at) END ASC,
      updated_at DESC,id
    LIMIT LEAST(GREATEST(COALESCE(p_limit,80),1),240)
    OFFSET GREATEST(COALESCE(p_offset,0),0)
  ) SELECT jsonb_build_object(
    'orders',COALESCE((SELECT jsonb_agg((to_jsonb(po)-'approval_snapshot') || jsonb_build_object(
      'supplier',jsonb_build_object('id',s.id,'supplier_name',s.supplier_name),
      'store',jsonb_build_object('id',r.id,'name',r.name)) ORDER BY
        CASE WHEN po.status IN ('draft','submitted','store_approved','office_returned') THEN 0 ELSE 1 END,
        CASE WHEN po.status IN ('draft','submitted','store_approved','office_returned')
          THEN COALESCE(po.submitted_at,po.created_at) END ASC,
        po.updated_at DESC,po.id)
      FROM page po JOIN public.inventory_suppliers s ON s.id=po.supplier_id
      JOIN public.restaurants r ON r.id=po.restaurant_id),'[]'::jsonb),
    'total',(SELECT count(*) FROM filtered),
    'counts',COALESCE((SELECT jsonb_object_agg(status,n) FROM
      (SELECT status,count(*) n FROM filtered GROUP BY status) c),'{}'::jsonb),
    'stores',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',r.id,'name',r.name) ORDER BY r.name)
      FROM public.restaurants r WHERE public.can_access_inventory_workflow(r.id)),'[]'::jsonb)
  ) INTO result;
  RETURN result;
END $$;

REVOKE ALL ON FUNCTION public.search_inventory_workflow_orders(
  uuid,text[],boolean,integer,integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.search_inventory_workflow_orders(
  uuid,text[],boolean,integer,integer,text) TO authenticated;
COMMIT;
