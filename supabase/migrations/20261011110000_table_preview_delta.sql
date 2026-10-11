BEGIN;
CREATE OR REPLACE FUNCTION public.get_table_order_previews_delta(p_store_id uuid,p_order_ids uuid[],p_table_ids uuid[] DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=public,auth,pg_catalog AS $$
DECLARE v_rows jsonb;
BEGIN
 IF auth.uid() IS NULL OR p_store_id IS NULL OR COALESCE(cardinality(p_order_ids),0) NOT BETWEEN 1 AND 50
   OR p_table_ids IS NULL OR cardinality(p_table_ids)>50 OR array_position(p_order_ids,NULL) IS NOT NULL
   OR array_position(p_table_ids,NULL) IS NOT NULL THEN RAISE EXCEPTION 'TABLE_PREVIEW_QUERY_INVALID'; END IF;
 WITH affected AS MATERIALIZED (
   SELECT table_id FROM public.orders WHERE restaurant_id=p_store_id AND id=ANY(p_order_ids) AND table_id IS NOT NULL
   UNION SELECT id FROM public.tables WHERE restaurant_id=p_store_id AND id=ANY(p_table_ids)
 ), selected AS MATERIALIZED (
   SELECT DISTINCT ON(o.table_id) o.id,o.table_id,o.created_at FROM public.orders o JOIN affected a ON a.table_id=o.table_id
   WHERE o.restaurant_id=p_store_id AND o.status NOT IN ('completed','cancelled') ORDER BY o.table_id,o.created_at DESC,o.id DESC
 ), items AS (
   SELECT i.order_id,jsonb_agg(jsonb_build_object('id',i.id,'created_at',i.created_at,'label',i.label,
    'quantity',i.quantity,'status',i.status,'menu_items',jsonb_build_object('name',m.name,'name_ko',m.name_ko,'name_vi',m.name_vi,'name_en',m.name_en))
    ORDER BY i.created_at,i.id) rows FROM selected s JOIN public.order_items i ON i.order_id=s.id
    LEFT JOIN public.menu_items m ON m.id=i.menu_item_id WHERE i.status IS DISTINCT FROM 'cancelled' GROUP BY i.order_id
 ) SELECT coalesce(jsonb_agg(jsonb_build_object('table_id',a.table_id,'id',s.id,'created_at',s.created_at,'order_items',coalesce(i.rows,'[]')) ORDER BY a.table_id),'[]')
 INTO v_rows FROM affected a LEFT JOIN selected s ON s.table_id=a.table_id LEFT JOIN items i ON i.order_id=s.id;
 RETURN jsonb_build_object('version',1,'rows',v_rows);
END $$;
REVOKE ALL ON FUNCTION public.get_table_order_previews_delta(uuid,uuid[],uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_table_order_previews_delta(uuid,uuid[],uuid[]) TO authenticated;
COMMIT;
