BEGIN;
CREATE FUNCTION public.procurement_allowed_actions(p_request public.inventory_purchase_requests,p_actor jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
 SELECT to_jsonb(array_remove(ARRAY[
 CASE WHEN p_request.status IN ('draft','returned') AND p_request.created_actor->>'system'=p_actor->>'system'
   AND p_request.created_actor->>'subject_id'=p_actor->>'subject_id' AND (p_actor->>'can_create')::boolean THEN 'save_request' END,
 CASE WHEN p_request.status IN ('draft','returned') AND p_request.created_actor->>'system'=p_actor->>'system'
   AND p_request.created_actor->>'subject_id'=p_actor->>'subject_id' AND (p_actor->>'can_create')::boolean THEN 'submit_request' END,
 CASE WHEN p_request.status='submitted' AND (p_actor->>'can_store_approve')::boolean THEN 'store_approve' END,
 CASE WHEN p_request.status='submitted' AND (p_actor->>'can_store_approve')::boolean
   OR p_request.status IN ('office_review','senior_review') AND (p_actor->>'can_office_approve')::boolean THEN 'return_request' END,
 CASE WHEN p_request.status IN ('office_review','senior_review','approved') AND (p_actor->>'can_office_approve')::boolean THEN 'save_quote' END,
 CASE WHEN p_request.status IN ('office_review','senior_review','approved') AND (p_actor->>'can_office_approve')::boolean THEN 'select_quote' END,
 CASE WHEN p_request.status='office_review' AND (p_actor->>'can_office_approve')::boolean THEN 'office_approve' END,
 CASE WHEN p_request.status='senior_review' AND (p_actor->>'can_senior_approve')::boolean
   AND (p_request.office_approved_actor->>'system'<>p_actor->>'system' OR p_request.office_approved_actor->>'subject_id'<>p_actor->>'subject_id') THEN 'senior_approve' END,
 CASE WHEN p_request.status='approved' AND (p_actor->>'can_office_approve')::boolean THEN 'issue_po' END
 ]::text[],NULL))
$$;
REVOKE ALL ON FUNCTION public.procurement_allowed_actions(public.inventory_purchase_requests,jsonb) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.procurement_workspace(p_store_id uuid,p_request_id uuid DEFAULT NULL,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb; policy jsonb; prices boolean; enabled boolean;
BEGIN
 actor:=public.procurement_actor(p_store_id,p_office_actor);
 prices:=COALESCE((actor->>'can_view_prices')::boolean,false);
 SELECT to_jsonb(p) INTO policy FROM public.procurement_store_policies p WHERE restaurant_id=p_store_id;
 enabled:=COALESCE((policy->>'enabled')::boolean,false);
 RETURN jsonb_build_object('contract_version',2,'store_id',p_store_id,'enabled',enabled,'actor',actor,'policy',policy,
 'products',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'stock_unit',p.stock_unit,'base_unit',p.base_unit,
   'conversion',p.base_unit_factor,'current_stock',it.current_stock,'stock_updated_at',it.updated_at))
   FROM public.inventory_products p LEFT JOIN public.inventory_items it ON it.id=p.inventory_item_id AND it.restaurant_id=p_store_id
   WHERE p.restaurant_id=p_store_id AND p.is_active AND p.is_orderable),'[]'::jsonb),
 'supplier_items',COALESCE((SELECT jsonb_agg(CASE WHEN prices THEN to_jsonb(i) ELSE to_jsonb(i)-'unit_price'-'tax_rate' END ||
   jsonb_build_object('supplier_name',s.supplier_name,'product_name',p.name,'payment_terms',s.payment_terms))
   FROM public.inventory_supplier_items i JOIN public.inventory_products p ON p.id=i.product_id
   JOIN public.inventory_suppliers s ON s.id=i.supplier_id WHERE p.restaurant_id=p_store_id AND p.is_active AND i.is_active AND s.status='active' AND (s.brand_id IS NULL OR s.brand_id=(SELECT brand_id FROM public.restaurants WHERE id=p_store_id))),'[]'::jsonb),
 'requests',COALESCE((SELECT jsonb_agg(CASE WHEN prices THEN to_jsonb(r) ELSE to_jsonb(r)-'approved_amount' END || jsonb_build_object(
   'allowed_actions',CASE WHEN enabled THEN public.procurement_allowed_actions(r,actor) ELSE '[]'::jsonb END,
   'lines',(SELECT COALESCE(jsonb_agg(to_jsonb(l)||jsonb_build_object('product_name',p.name) ORDER BY l.id),'[]'::jsonb)
     FROM public.inventory_purchase_request_lines l JOIN public.inventory_products p ON p.id=l.product_id WHERE l.request_id=r.id AND l.active),
   'quotes',CASE WHEN prices THEN (SELECT COALESCE(jsonb_agg(to_jsonb(q)||jsonb_build_object('supplier_name',s.supplier_name,'lines',
     (SELECT jsonb_agg(to_jsonb(l)) FROM public.procurement_quote_lines l WHERE l.quote_id=q.id)) ORDER BY q.created_at),'[]'::jsonb)
     FROM public.procurement_quotes q JOIN public.inventory_suppliers s ON s.id=q.supplier_id WHERE q.request_id=r.id AND NOT q.archived) ELSE '[]'::jsonb END
 )) FROM (SELECT * FROM public.inventory_purchase_requests WHERE restaurant_id=p_store_id AND (p_request_id IS NULL OR id=p_request_id)
   ORDER BY updated_at DESC,id LIMIT 100) r),'[]'::jsonb),
 'orders',COALESCE((SELECT jsonb_agg((CASE WHEN prices THEN to_jsonb(po) ELSE to_jsonb(po)-'total_amount'-'total_supply_amount'-'tax_amount'-'approval_snapshot' END)||
   jsonb_build_object('supplier_name',(SELECT supplier_name FROM public.inventory_suppliers WHERE id=po.supplier_id),
   'allowed_actions',CASE WHEN NOT enabled OR NOT COALESCE((actor->>'can_office_approve')::boolean,false) THEN '[]'::jsonb
     WHEN po.procurement_status='issued' THEN '["send_po"]'::jsonb WHEN po.procurement_status='sent' THEN '["confirm_po"]'::jsonb ELSE '[]'::jsonb END))
   FROM (SELECT * FROM public.inventory_purchase_orders WHERE restaurant_id=p_store_id AND workflow_version=2
     AND (p_request_id IS NULL OR commercial_terms->>'request_id'=p_request_id::text) ORDER BY created_at DESC,id LIMIT 100) po),'[]'::jsonb),
 'events',COALESCE((SELECT jsonb_agg(to_jsonb(e)) FROM (SELECT ev.id,ev.record_id,ev.action,ev.actor,ev.reason,ev.created_at FROM public.procurement_events ev
   WHERE restaurant_id=p_store_id AND (p_request_id IS NULL OR record_id=p_request_id) ORDER BY created_at DESC LIMIT 100) e),'[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.procurement_workspace(uuid,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_workspace(uuid,uuid,jsonb) TO authenticated,service_role;

CREATE FUNCTION public.guard_procurement_v2_order_write()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF (NEW.workflow_version=2 OR (TG_OP IN ('UPDATE','DELETE') AND OLD.workflow_version=2))
   AND COALESCE(current_setting('app.procurement_write',true),'')<>'true' THEN
   RAISE EXCEPTION 'PROCUREMENT_V2_COMMAND_REQUIRED'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER procurement_v2_order_guard BEFORE INSERT OR UPDATE OR DELETE ON public.inventory_purchase_orders
FOR EACH ROW EXECUTE FUNCTION public.guard_procurement_v2_order_write();
REVOKE ALL ON FUNCTION public.guard_procurement_v2_order_write() FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.guard_procurement_v2_line_write()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE order_id uuid;
BEGIN
 order_id:=CASE WHEN TG_OP='DELETE' THEN OLD.purchase_order_id ELSE NEW.purchase_order_id END;
 IF EXISTS(SELECT 1 FROM public.inventory_purchase_orders WHERE id=order_id AND workflow_version=2)
   AND COALESCE(current_setting('app.procurement_write',true),'')<>'true' THEN RAISE EXCEPTION 'PROCUREMENT_V2_COMMAND_REQUIRED'; END IF;
 IF TG_OP='UPDATE' AND OLD.purchase_order_id<>NEW.purchase_order_id THEN RAISE EXCEPTION 'PROCUREMENT_LINE_REPARENT_FORBIDDEN'; END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER procurement_v2_line_guard BEFORE INSERT OR UPDATE OR DELETE ON public.inventory_purchase_order_lines
FOR EACH ROW EXECUTE FUNCTION public.guard_procurement_v2_line_write();
REVOKE ALL ON FUNCTION public.guard_procurement_v2_line_write() FROM PUBLIC,anon,authenticated;

ALTER FUNCTION public.verify_inventory_receipt(uuid,integer,text,jsonb,text) RENAME TO verify_inventory_receipt_p1;
REVOKE ALL ON FUNCTION public.verify_inventory_receipt_p1(uuid,integer,text,jsonb,text) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.verify_inventory_receipt(p_receipt_id uuid,p_expected_version integer,p_idempotency_key text,
 p_lines jsonb DEFAULT '[]',p_verification_reason text DEFAULT NULL)
RETURNS public.inventory_purchase_orders LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE po public.inventory_purchase_orders%rowtype; result public.inventory_purchase_orders%rowtype;
 saved_write text:=current_setting('app.procurement_write',true);
BEGIN
 SELECT o.* INTO po FROM public.inventory_purchase_orders o JOIN public.inventory_receipts r ON r.purchase_order_id=o.id WHERE r.id=p_receipt_id FOR UPDATE OF o;
 IF po.workflow_version=2 AND po.procurement_status<>'confirmed' THEN RAISE EXCEPTION 'PROCUREMENT_SUPPLIER_CONFIRMATION_REQUIRED'; END IF;
 PERFORM set_config('app.procurement_write','true',true);
 result:=public.verify_inventory_receipt_p1(p_receipt_id,p_expected_version,p_idempotency_key,p_lines,p_verification_reason);
 PERFORM set_config('app.procurement_write',COALESCE(saved_write,''),true);
 RETURN result;
END $$;
GRANT EXECUTE ON FUNCTION public.verify_inventory_receipt(uuid,integer,text,jsonb,text) TO authenticated,service_role;
REVOKE ALL ON FUNCTION public.verify_inventory_receipt(uuid,integer,text,jsonb,text) FROM PUBLIC,anon;
COMMIT;
