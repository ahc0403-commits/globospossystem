-- Move one registered dish within its category. Internal S/L/meal IDs never
-- participate in the displayed order. The category lock serializes moves and
-- the server derives the current order, so stale screens cannot undo a move.
CREATE FUNCTION public.admin_move_menu_item(
 p_store_id uuid, p_category_id uuid, p_item_id uuid, p_move text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE ids uuid[]; source_index integer; target_index integer;
BEGIN
 PERFORM public.require_admin_actor_for_restaurant(p_store_id);
 IF p_move IS NULL OR p_move NOT IN ('first','up','down') THEN
  RAISE EXCEPTION 'MENU_ITEM_ORDER_MOVE_INVALID';
 END IF;
 PERFORM 1 FROM public.menu_categories
 WHERE id=p_category_id AND restaurant_id=p_store_id AND is_active FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND'; END IF;
 PERFORM 1 FROM public.menu_items
 WHERE restaurant_id=p_store_id AND category_id=p_category_id
  AND size_parent_id IS NULL AND NOT is_archived ORDER BY id FOR UPDATE;
 SELECT array_agg(id ORDER BY sort_order,id) INTO ids FROM public.menu_items
 WHERE restaurant_id=p_store_id AND category_id=p_category_id
  AND size_parent_id IS NULL AND NOT is_archived;
 source_index:=array_position(ids,p_item_id);
 IF source_index IS NULL THEN RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND'; END IF;
 target_index:=CASE p_move WHEN 'first' THEN 1
  WHEN 'up' THEN greatest(1,source_index-1)
  ELSE least(cardinality(ids),source_index+1) END;
 IF source_index<>target_index THEN
  ids:=array_remove(ids,p_item_id);
  ids:=ids[1:target_index-1] || ARRAY[p_item_id] || ids[target_index:cardinality(ids)];
  -- One set-based update; no per-menu RPCs or reads. Existing option triggers
  -- preserve keys, prices, invoice mappings and historical order snapshots.
  UPDATE public.menu_items m SET sort_order=o.position-1,updated_at=now()
  FROM unnest(ids) WITH ORDINALITY o(id,position)
  WHERE m.id=o.id AND m.restaurant_id=p_store_id AND m.category_id=p_category_id
   AND m.size_parent_id IS NULL AND NOT m.is_archived
   AND m.sort_order IS DISTINCT FROM o.position-1;
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
  VALUES(auth.uid(),'admin_move_menu_item','menu_items',p_item_id,
   jsonb_build_object('store_id',p_store_id,'category_id',p_category_id,
    'move',p_move,'from_index',source_index-1,'to_index',target_index-1,'item_ids',to_jsonb(ids)));
 END IF;
 -- Return only ordering fields; the existing UI cache keeps photos and combos.
 RETURN (SELECT jsonb_agg(jsonb_build_object('id',m.id,'sort_order',m.sort_order)
  ORDER BY m.sort_order,m.id) FROM public.menu_items m
  WHERE m.id=ANY(ids) AND m.restaurant_id=p_store_id AND m.category_id=p_category_id);
END $$;
REVOKE ALL ON FUNCTION public.admin_move_menu_item(uuid,uuid,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.admin_move_menu_item(uuid,uuid,uuid,text) TO authenticated;
