-- Extend the existing manager adjustment command; retain its actor, stage,
-- row lock, expected-version, idempotency and immutable requester contracts.
-- production-gate: self-verifying
BEGIN;
CREATE FUNCTION public.procurement_insert_adjustment_lines(
 p_store_id uuid,p_request_id uuid,p_new_lines jsonb
) RETURNS void LANGUAGE plpgsql SET search_path=public,auth,pg_catalog AS $body$
DECLARE expected_count integer;inserted_count integer;last_position integer;
BEGIN
 IF jsonb_typeof(p_new_lines) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'PROCUREMENT_LINES_REQUIRED'; END IF;
 expected_count:=jsonb_array_length(p_new_lines);
 IF expected_count=0 THEN RETURN; END IF;
 IF expected_count>200 OR expected_count+(SELECT count(*) FROM public.inventory_purchase_request_lines WHERE request_id=p_request_id AND active)>200 THEN RAISE EXCEPTION 'PROCUREMENT_LINES_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_new_lines) x
   LEFT JOIN public.inventory_products p ON p.id=(x->>'product_id')::uuid AND p.restaurant_id=p_store_id AND p.is_active AND p.is_orderable
   WHERE p.id IS NULL) THEN RAISE EXCEPTION 'PROCUREMENT_PRODUCT_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_new_lines) x WHERE
   (x->>'quantity')::numeric IS NULL OR (x->>'quantity')::numeric<=0 OR
   (x->>'quantity')::numeric<>round((x->>'quantity')::numeric,3) OR
   (x->>'quantity')::numeric::text IN ('NaN','Infinity','-Infinity')) THEN RAISE EXCEPTION 'PROCUREMENT_QUANTITY_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_new_lines) x JOIN public.inventory_products p ON p.id=(x->>'product_id')::uuid
   WHERE x->>'unit' IS NULL OR x->>'unit' NOT IN (p.base_unit,p.stock_unit)
     OR x->>'unit'<>p.base_unit AND COALESCE(p.base_unit_factor,0)<=0) THEN RAISE EXCEPTION 'PROCUREMENT_UNIT_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_new_lines) x GROUP BY x->>'product_id' HAVING count(*)>1)
   OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_new_lines) x JOIN public.inventory_purchase_request_lines l
     ON l.request_id=p_request_id AND l.active AND l.product_id=(x->>'product_id')::uuid)
 THEN RAISE EXCEPTION 'PROCUREMENT_LINE_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_new_lines) x JOIN public.inventory_products p ON p.id=(x->>'product_id')::uuid
   WHERE NULLIF(x->>'preferred_supplier_id','') IS NOT NULL AND NOT EXISTS(
     SELECT 1 FROM public.inventory_supplier_items si JOIN public.inventory_suppliers s ON s.id=si.supplier_id
     WHERE si.product_id=p.id AND si.supplier_id=(x->>'preferred_supplier_id')::uuid AND si.is_active AND s.status='active'
       AND(s.brand_id IS NULL OR s.brand_id=(SELECT brand_id FROM public.restaurants WHERE id=p_store_id))))
 THEN RAISE EXCEPTION 'PROCUREMENT_SUPPLIER_INVALID'; END IF;
 SELECT COALESCE(max(line_position),0) INTO last_position FROM public.inventory_purchase_request_lines WHERE request_id=p_request_id;
     INSERT INTO public.inventory_purchase_request_lines(request_id,product_id,requested_quantity,requested_unit,quantity_base,conversion_snapshot,
       current_stock_snapshot,stock_updated_at,preferred_supplier_id,memo,product_name_snapshot,specification_snapshot,receipt_classification,
       estimated_unit_price,estimated_tax_rate,estimated_conversion,estimated_order_unit,estimated_supplier_item_id,product_code_snapshot,line_position)
     WITH eligible AS MATERIALIZED (
       SELECT si.* FROM public.inventory_supplier_items si
       JOIN public.inventory_products p ON p.id=si.product_id AND p.restaurant_id=p_store_id
       JOIN public.inventory_suppliers s ON s.id=si.supplier_id AND s.status='active'
         AND (s.brand_id IS NULL OR s.brand_id=(SELECT brand_id FROM public.restaurants WHERE id=p_store_id))
       WHERE si.is_active AND si.product_id IN (SELECT (x.value->>'product_id')::uuid FROM jsonb_array_elements(p_new_lines) x)
     ), estimates AS (
       SELECT DISTINCT ON (product_id,supplier_id) * FROM eligible ORDER BY product_id,supplier_id,is_preferred DESC,id
     ), ranked AS (
       SELECT e.*,dense_rank() OVER(PARTITION BY product_id ORDER BY is_preferred DESC) priority FROM eligible e
     ), preferred AS (
       SELECT r.*,count(*) OVER(PARTITION BY product_id) choices FROM ranked r WHERE priority=1
     ), defaults AS (SELECT * FROM preferred WHERE choices=1)
     SELECT p_request_id,p.id,(x.value->>'quantity')::numeric,x.value->>'unit',
       (x.value->>'quantity')::numeric*CASE WHEN x.value->>'unit'=p.base_unit THEN 1 ELSE p.base_unit_factor END,
       CASE WHEN x.value->>'unit'=p.base_unit THEN 1 ELSE p.base_unit_factor END,it.current_stock,it.updated_at,
       NULLIF(x.value->>'preferred_supplier_id','')::uuid,x.value->>'memo',p.name,p.specification,p.receipt_classification,
       CASE WHEN NULLIF(x.value->>'preferred_supplier_id','') IS NULL THEN d.unit_price ELSE e.unit_price END,
       CASE WHEN NULLIF(x.value->>'preferred_supplier_id','') IS NULL THEN d.tax_rate ELSE e.tax_rate END,
       CASE WHEN NULLIF(x.value->>'preferred_supplier_id','') IS NULL THEN d.order_unit_quantity_base ELSE e.order_unit_quantity_base END,
       CASE WHEN NULLIF(x.value->>'preferred_supplier_id','') IS NULL THEN d.order_unit ELSE e.order_unit END,
       CASE WHEN NULLIF(x.value->>'preferred_supplier_id','') IS NULL THEN d.id ELSE e.id END,p.product_code,last_position+x.ordinality
     FROM jsonb_array_elements(p_new_lines) WITH ORDINALITY x(value,ordinality) JOIN public.inventory_products p ON p.id=(x.value->>'product_id')::uuid
     LEFT JOIN public.inventory_items it ON it.id=p.inventory_item_id AND it.restaurant_id=p_store_id
     LEFT JOIN estimates e ON e.product_id=p.id AND e.supplier_id=NULLIF(x.value->>'preferred_supplier_id','')::uuid
     LEFT JOIN defaults d ON d.product_id=p.id
     WHERE p.restaurant_id=p_store_id AND p.is_active AND p.is_orderable
       AND x.value->>'unit' IN (p.base_unit,p.stock_unit)
       AND (x.value->>'unit'=p.base_unit OR p.base_unit_factor>0);
 GET DIAGNOSTICS inserted_count=ROW_COUNT;
 IF inserted_count<>expected_count THEN RAISE EXCEPTION 'PROCUREMENT_PRODUCT_INVALID'; END IF;
END $body$;
REVOKE ALL ON FUNCTION public.procurement_insert_adjustment_lines(uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;

DO $patch$
DECLARE d text;old_fragment text;new_fragment text;
BEGIN
 d:=pg_get_functiondef('public.procurement_core_command(uuid,text,uuid,integer,text,jsonb,jsonb)'::regprocedure);
 old_fragment:=$old$       UPDATE public.inventory_purchase_request_lines l SET requested_quantity=(x->>'quantity')::numeric,$old$;
 new_fragment:=$new$       IF p_payload ? 'new_lines' THEN
         PERFORM public.procurement_insert_adjustment_lines(p_store_id,req.id,p_payload->'new_lines');
       END IF;
       UPDATE public.inventory_purchase_request_lines l SET requested_quantity=(x->>'quantity')::numeric,$new$;
 IF position(old_fragment IN d)=0 OR position('procurement_insert_adjustment_lines' IN d)>0 THEN RAISE EXCEPTION 'PROCUREMENT_ADJUSTMENT_PATCH_MISMATCH'; END IF;
 d:=replace(d,old_fragment,new_fragment);
 old_fragment:=$old$ INSERT INTO public.procurement_events(restaurant_id,record_id,action,actor,previous_state,next_state,reason)$old$;
 new_fragment:=$new$ IF p_action='adjust_request' THEN
   result:=result||jsonb_build_object('lines',(SELECT jsonb_agg(to_jsonb(l) ORDER BY l.line_position,l.id)
     FROM public.inventory_purchase_request_lines l WHERE l.request_id=req.id AND l.active));
 END IF;
 INSERT INTO public.procurement_events(restaurant_id,record_id,action,actor,previous_state,next_state,reason)$new$;
 IF position(old_fragment IN d)=0 THEN RAISE EXCEPTION 'PROCUREMENT_ADJUSTMENT_AUDIT_PATCH_MISMATCH'; END IF;
 EXECUTE replace(d,old_fragment,new_fragment);
END $patch$;

-- An older server ignores unknown command payload keys. Advertise support only
-- after the atomic command has been installed, so mixed-version clients cannot
-- silently lose newly added items.
ALTER FUNCTION public.procurement_workspace_page(uuid,jsonb,jsonb) RENAME TO procurement_pre_manager_adjustment_page;
REVOKE ALL ON FUNCTION public.procurement_pre_manager_adjustment_page(uuid,jsonb,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.procurement_workspace_page(p_store_id uuid,p_query jsonb DEFAULT '{}',p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $page$
DECLARE result jsonb;
BEGIN
 result:=public.procurement_pre_manager_adjustment_page(p_store_id,p_query,p_office_actor);
 IF result ? 'requests' THEN RETURN result||jsonb_build_object('adjustment_additions_version',1); END IF;
 RETURN result;
END $page$;
REVOKE ALL ON FUNCTION public.procurement_workspace_page(uuid,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_workspace_page(uuid,jsonb,jsonb) TO authenticated,service_role;

DO $verify$
BEGIN
 IF has_function_privilege('authenticated','public.procurement_insert_adjustment_lines(uuid,uuid,jsonb)','EXECUTE')
   OR has_function_privilege('service_role','public.procurement_insert_adjustment_lines(uuid,uuid,jsonb)','EXECUTE')
   OR position('procurement_insert_adjustment_lines' IN pg_get_functiondef('public.procurement_core_command(uuid,text,uuid,integer,text,jsonb,jsonb)'::regprocedure))=0
 THEN RAISE EXCEPTION 'PROCUREMENT_ADJUSTMENT_BOUNDARY_INVALID'; END IF;
END $verify$;
COMMIT;
