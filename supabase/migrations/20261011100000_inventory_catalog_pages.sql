BEGIN;
CREATE OR REPLACE FUNCTION public.get_inventory_catalog_page(
  p_store_id uuid,p_source text,p_query text DEFAULT NULL,p_supplier_id uuid DEFAULT NULL,
  p_product_id uuid DEFAULT NULL,p_after_id uuid DEFAULT NULL,p_limit integer DEFAULT 50
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=public,auth,pg_catalog AS $$
DECLARE v_rows jsonb; v_more boolean; v_stats jsonb; v_query text:=NULLIF(btrim(p_query),'');
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_read_inventory_purchase_store(p_store_id) THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_CATALOG_FORBIDDEN'; END IF;
  IF p_source IS NULL OR p_source NOT IN ('products','supplier_items','ingredient_export') OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 500
    OR length(COALESCE(v_query,''))>100 THEN RAISE EXCEPTION 'INVENTORY_CATALOG_QUERY_INVALID'; END IF;
  IF p_source IN ('products','ingredient_export') THEN
    SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.id),'[]') INTO v_rows FROM (
      SELECT p.id,p.restaurant_id,p.brand_id,p.inventory_item_id,p.product_code,p.name,p.category,
        p.stock_unit,p.base_unit,p.base_unit_factor,p.image_url,p.storage_type,p.shelf_life_days,
        p.is_orderable,p.is_active,p.created_at,p.updated_at,
        CASE WHEN p_source='ingredient_export' THEN (
          SELECT jsonb_build_object('supplier_name',s.supplier_name,'unit_price',link.unit_price)
          FROM public.inventory_supplier_items link JOIN public.inventory_suppliers s ON s.id=link.supplier_id
          WHERE link.product_id=p.id AND link.is_active AND s.status='active'
          ORDER BY link.is_preferred DESC,link.updated_at DESC,link.id LIMIT 1
        ) ELSE NULL END AS export_supplier,
        CASE WHEN i.id IS NULL THEN NULL ELSE jsonb_build_object('current_stock',i.current_stock,'reorder_point',i.reorder_point,'cost_per_unit',i.cost_per_unit,'supplier_name',i.supplier_name) END AS inventory_item
      FROM public.inventory_products p LEFT JOIN public.inventory_items i ON i.id=p.inventory_item_id AND i.restaurant_id=p.restaurant_id
      WHERE p.restaurant_id=p_store_id AND (p_after_id IS NULL OR p.id>p_after_id)
        AND (v_query IS NULL OR p.name ILIKE '%'||v_query||'%' OR p.product_code ILIKE '%'||v_query||'%')
      ORDER BY p.id LIMIT p_limit+1
    )q;
    IF p_after_id IS NULL AND p_source='products' THEN
      SELECT jsonb_build_object('total',count(*),'active',count(*) FILTER(WHERE is_active),'orderable',count(*) FILTER(WHERE is_orderable),'supplier_links',(SELECT count(*) FROM public.inventory_supplier_items link JOIN public.inventory_products scoped ON scoped.id=link.product_id WHERE scoped.restaurant_id=p_store_id)) INTO v_stats
      FROM public.inventory_products p WHERE p.restaurant_id=p_store_id
        AND (v_query IS NULL OR p.name ILIKE '%'||v_query||'%' OR p.product_code ILIKE '%'||v_query||'%');
    END IF;
  ELSE
    SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.id),'[]') INTO v_rows FROM (
      SELECT i.id,i.supplier_id,i.product_id,i.supplier_sku,i.order_unit,i.order_unit_quantity_base,
        i.min_order_quantity,i.unit_price,i.tax_rate,i.lead_time_days,i.is_preferred,i.is_active,i.created_at,i.updated_at,
        jsonb_build_object('id',s.id,'supplier_name',s.supplier_name,'status',s.status) AS supplier,
        jsonb_build_object('id',p.id,'restaurant_id',p.restaurant_id,'name',p.name,'product_code',p.product_code,
          'category',p.category,'stock_unit',p.stock_unit,'base_unit',p.base_unit,'base_unit_factor',p.base_unit_factor,
          'is_orderable',p.is_orderable,'is_active',p.is_active) AS product
      FROM public.inventory_supplier_items i JOIN public.inventory_products p ON p.id=i.product_id
      JOIN public.inventory_suppliers s ON s.id=i.supplier_id
      WHERE p.restaurant_id=p_store_id AND (p_after_id IS NULL OR i.id>p_after_id)
        AND (p_supplier_id IS NULL OR i.supplier_id=p_supplier_id) AND (p_product_id IS NULL OR i.product_id=p_product_id)
        AND (v_query IS NULL OR p.name ILIKE '%'||v_query||'%' OR i.supplier_sku ILIKE '%'||v_query||'%')
      ORDER BY i.id LIMIT p_limit+1
    )q;
    IF p_after_id IS NULL THEN
      SELECT jsonb_build_object('total',count(*)) INTO v_stats FROM public.inventory_supplier_items i
      JOIN public.inventory_products p ON p.id=i.product_id JOIN public.inventory_suppliers s ON s.id=i.supplier_id
      WHERE p.restaurant_id=p_store_id AND (p_supplier_id IS NULL OR i.supplier_id=p_supplier_id)
        AND (p_product_id IS NULL OR i.product_id=p_product_id)
        AND (v_query IS NULL OR p.name ILIKE '%'||v_query||'%' OR i.supplier_sku ILIKE '%'||v_query||'%');
    END IF;
  END IF;
  v_more:=jsonb_array_length(v_rows)>p_limit;
  IF v_more THEN v_rows:=v_rows-p_limit; END IF;
  RETURN jsonb_build_object('version',1,'rows',v_rows,'has_more',v_more,'stats',v_stats);
END $$;
REVOKE ALL ON FUNCTION public.get_inventory_catalog_page(uuid,text,text,uuid,uuid,uuid,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_inventory_catalog_page(uuid,text,text,uuid,uuid,uuid,integer) TO authenticated;
COMMIT;
