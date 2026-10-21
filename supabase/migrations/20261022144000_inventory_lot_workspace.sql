-- Bounded lot workspace and count inputs; scope is checked before any rows leave
-- the server. Stock locations are independent of service areas and kitchens.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE FUNCTION public.inventory_lot_workspace_v1(p_store uuid,p_after uuid DEFAULT NULL,p_ingredient uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE actor jsonb; rows jsonb; tail uuid; result jsonb;
BEGIN
 actor:=procurement_actor(p_store);
 WITH page AS MATERIALIZED(SELECT l.* FROM inventory_lots l WHERE l.restaurant_id=p_store AND l.state IN('available','held','rejected') AND l.quantity_base>0 AND (p_after IS NULL OR l.id>p_after) AND (p_ingredient IS NULL OR l.ingredient_id=p_ingredient) ORDER BY l.id LIMIT 51),
 visible AS(SELECT * FROM page ORDER BY id LIMIT 50)
 SELECT jsonb_build_object('lots',coalesce(jsonb_agg(to_jsonb(l)||jsonb_build_object('ingredient_name',i.name,'unit',i.unit,'purchase_order_id',ol.purchase_order_id,'purchase_order_line_id',ol.id,'purchase_order_no',o.purchase_order_no,'order_version',o.row_version,'quality',to_jsonb(q)) ORDER BY l.id),'[]'),
 'next_cursor',CASE WHEN (SELECT count(*) FROM page)>50 THEN (SELECT id FROM visible ORDER BY id DESC LIMIT 1) END) INTO result
 FROM visible l JOIN inventory_items i ON i.id=l.ingredient_id LEFT JOIN inventory_receipt_lines rl ON rl.id=l.receipt_line_id
 LEFT JOIN inventory_purchase_order_lines ol ON ol.id=rl.purchase_order_line_id LEFT JOIN inventory_purchase_orders o ON o.id=ol.purchase_order_id
 LEFT JOIN procurement_effective_quality_v1(ARRAY(SELECT DISTINCT rl.purchase_order_line_id FROM visible v JOIN inventory_receipt_lines rl ON rl.id=v.receipt_line_id))q ON q.order_line_id=ol.id;
 RETURN result||jsonb_build_object('locations',coalesce((SELECT jsonb_agg(to_jsonb(loc) ORDER BY loc.id) FROM (SELECT id,name,kind,revision FROM inventory_locations WHERE restaurant_id=p_store AND is_active ORDER BY id LIMIT 101)loc),'[]'),
 'employees',coalesce((SELECT jsonb_agg(jsonb_build_object('id',e.id,'name',e.full_name) ORDER BY e.id) FROM (SELECT id,full_name FROM store_employees WHERE store_id=p_store AND is_active ORDER BY id LIMIT 201)e),'[]'),
 'can_dispose',can_verify_inventory_receipt(p_store));
END $$;
CREATE FUNCTION public.admin_get_inventory_count_inputs_v1(p_store uuid,p_after uuid DEFAULT NULL,p_ingredient uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb;
BEGIN
 PERFORM require_brand_admin_v1();
 WITH page AS MATERIALIZED(SELECT i.id,i.name,i.unit,i.current_stock,i.updated_at FROM inventory_items i WHERE i.restaurant_id=p_store AND i.is_active AND (p_after IS NULL OR i.id>p_after) AND (p_ingredient IS NULL OR i.id=p_ingredient) ORDER BY i.id LIMIT 51),
 visible AS(SELECT * FROM page ORDER BY id LIMIT 50),
 products AS(SELECT DISTINCT ON(p.inventory_item_id) p.inventory_item_id,p.id,p.base_unit FROM inventory_products p JOIN visible i ON i.id=p.inventory_item_id WHERE p.is_active AND p.receipt_classification='stock' ORDER BY p.inventory_item_id,p.id),
 counts AS(SELECT DISTINCT ON(c.ingredient_id) c.ingredient_id,c.data x,c.count_id id,c.created_at FROM inventory_lot_count_rows c JOIN visible v ON v.id=c.ingredient_id ORDER BY c.ingredient_id,c.created_at DESC,c.count_id DESC)
 SELECT jsonb_build_object('items',coalesce(jsonb_agg(to_jsonb(i)||jsonb_build_object('product_id',p.id,'base_unit',p.base_unit,'tracked',t.ingredient_id IS NOT NULL,'last_count_id',c.id,'last_count_at',c.created_at,'last_unit_cost_base',c.x->'unit_cost_base') ORDER BY i.id),'[]'),
 'next_cursor',CASE WHEN (SELECT count(*) FROM page)>50 THEN (SELECT id FROM visible ORDER BY id DESC LIMIT 1) END) INTO result
 FROM visible i LEFT JOIN products p ON p.inventory_item_id=i.id LEFT JOIN inventory_lot_tracking t ON t.ingredient_id=i.id LEFT JOIN counts c ON c.ingredient_id=i.id;
 RETURN result;
END $$;
-- Keep lot selection requirements explicit in the real receiving view.
ALTER FUNCTION public.get_inventory_workflow_detail(uuid) RENAME TO get_inventory_workflow_detail_before_lots;
REVOKE ALL ON FUNCTION public.get_inventory_workflow_detail_before_lots(uuid) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.get_inventory_workflow_detail(p_purchase_order_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE result jsonb; shop uuid; lines jsonb;
BEGIN
 result:=get_inventory_workflow_detail_before_lots(p_purchase_order_id);
 SELECT restaurant_id INTO shop FROM inventory_purchase_orders WHERE id=p_purchase_order_id;
 SELECT coalesce(jsonb_agg(x.value||jsonb_build_object('lot_tracking',t.ingredient_id IS NOT NULL,'held_quantity_base',coalesce(h.quantity_base,0)) ORDER BY x.ordinality),'[]') INTO lines
 FROM jsonb_array_elements(result->'lines') WITH ORDINALITY x(value,ordinality) JOIN inventory_purchase_order_lines ol ON ol.id=(x.value->>'id')::uuid JOIN inventory_products p ON p.id=ol.product_id LEFT JOIN inventory_lot_tracking t ON t.ingredient_id=p.inventory_item_id
 LEFT JOIN inventory_held_by_order_line_v1(ARRAY(SELECT id FROM inventory_purchase_order_lines WHERE purchase_order_id=p_purchase_order_id))h ON h.order_line_id=ol.id;
 RETURN jsonb_set(result,'{lines}',lines)||jsonb_build_object('inventory_locations',coalesce((SELECT jsonb_agg(jsonb_build_object('id',id,'name',name,'kind',kind) ORDER BY id) FROM inventory_locations WHERE restaurant_id=shop AND is_active),'[]'));
END $$;
-- Do not let a tracked ingredient silently opt out via a new quality version.
CREATE FUNCTION public.inventory_guard_lot_quality_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM new_lot_profiles q JOIN inventory_products p ON p.id=q.product_id JOIN inventory_lot_tracking t ON t.ingredient_id=p.inventory_item_id WHERE q.criteria->>'lot_required' IS DISTINCT FROM 'true') THEN RAISE EXCEPTION 'INVENTORY_LOT_TRACKING_CANNOT_DISABLE'; END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER inventory_guard_lot_quality AFTER INSERT ON public.procurement_quality_profiles REFERENCING NEW TABLE AS new_lot_profiles FOR EACH STATEMENT EXECUTE FUNCTION public.inventory_guard_lot_quality_v1();
-- Location/employee response caps are explicit, never silently missing choices.
CREATE FUNCTION public.inventory_guard_location_limit_v1() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT restaurant_id FROM inventory_locations WHERE restaurant_id IN(SELECT restaurant_id FROM new_inventory_locations) AND is_active GROUP BY restaurant_id HAVING count(*)>100) THEN RAISE EXCEPTION 'INVENTORY_LOCATION_LIMIT'; END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER inventory_guard_location_limit_insert AFTER INSERT ON public.inventory_locations REFERENCING NEW TABLE AS new_inventory_locations FOR EACH STATEMENT EXECUTE FUNCTION public.inventory_guard_location_limit_v1();
CREATE TRIGGER inventory_guard_location_limit_update AFTER UPDATE ON public.inventory_locations REFERENCING NEW TABLE AS new_inventory_locations FOR EACH STATEMENT EXECUTE FUNCTION public.inventory_guard_location_limit_v1();
REVOKE ALL ON FUNCTION public.inventory_guard_lot_quality_v1(),public.inventory_guard_location_limit_v1() FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.inventory_lot_workspace_v1(uuid,uuid,uuid),public.admin_get_inventory_count_inputs_v1(uuid,uuid,uuid),public.get_inventory_workflow_detail(uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.inventory_lot_workspace_v1(uuid,uuid,uuid),public.admin_get_inventory_count_inputs_v1(uuid,uuid,uuid),public.get_inventory_workflow_detail(uuid) TO authenticated;
COMMIT;
