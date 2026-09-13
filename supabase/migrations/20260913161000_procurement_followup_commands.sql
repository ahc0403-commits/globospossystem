BEGIN;
CREATE TABLE public.inventory_supplier_returns(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 receipt_line_id uuid NOT NULL REFERENCES public.inventory_receipt_lines(id), purchase_order_id uuid NOT NULL REFERENCES public.inventory_purchase_orders(id),
 quantity_base numeric(12,3) NOT NULL CHECK(quantity_base>0), reason text NOT NULL, evidence_reference text NOT NULL,
 actor jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.inventory_supplier_returns ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.inventory_supplier_returns FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.inventory_supplier_returns TO service_role;

ALTER FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) RENAME TO procurement_core_command;
REVOKE ALL ON FUNCTION public.procurement_core_command(uuid,text,uuid,integer,text,jsonb,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.procurement_command(p_store_id uuid,p_action text,p_record_id uuid,p_expected_version integer,p_idempotency_key text,p_payload jsonb DEFAULT '{}',p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb; prior public.procurement_command_results%rowtype; input_hash text; actor_key text; result jsonb; before_state jsonb;
 po public.inventory_purchase_orders%rowtype; issue public.inventory_receipt_issues%rowtype; rl public.inventory_receipt_lines%rowtype;
 product public.inventory_products%rowtype; qty numeric; already_returned numeric; stock numeric; accepted numeric; saved_write text:=current_setting('app.procurement_write',true);
BEGIN
 IF p_action='repair_legacy_terms' THEN RETURN public.procurement_repair_legacy_terms(p_store_id,p_record_id,p_expected_version,p_idempotency_key,p_payload,p_office_actor); END IF;
 IF p_action NOT IN ('resolve_issue','cancel_remaining','return_goods','amend_po') THEN
   RETURN public.procurement_core_command(p_store_id,p_action,p_record_id,p_expected_version,p_idempotency_key,p_payload,p_office_actor);
 END IF;
 actor:=public.procurement_actor(p_store_id,p_office_actor);actor_key:=(actor->>'system')||':'||(actor->>'subject_id');
 IF NULLIF(btrim(p_idempotency_key),'') IS NULL OR length(p_idempotency_key)>160 THEN RAISE EXCEPTION 'PROCUREMENT_IDEMPOTENCY_KEY_REQUIRED'; END IF;
 input_hash:=encode(extensions.digest(convert_to(jsonb_build_object('action',p_action,'record',p_record_id,'version',p_expected_version,'payload',p_payload)::text,'UTF8'),'sha256'),'hex');
 PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text||':'||p_idempotency_key,0));
 SELECT * INTO prior FROM public.procurement_command_results WHERE restaurant_id=p_store_id AND idempotency_key=p_idempotency_key;
 IF FOUND THEN
   IF prior.actor_key<>actor_key OR prior.payload_hash<>input_hash THEN RAISE EXCEPTION 'PROCUREMENT_RETRY_MISMATCH'; END IF;
   RETURN prior.result;
 END IF;
 PERFORM 1 FROM public.procurement_store_policies WHERE restaurant_id=p_store_id AND enabled FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_NOT_ENABLED'; END IF;
 IF NULLIF(btrim(p_payload->>'reason'),'') IS NULL OR NULLIF(btrim(p_payload->>'evidence_reference'),'') IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_REASON_EVIDENCE_REQUIRED'; END IF;
 IF p_action='resolve_issue' THEN
   IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_OFFICE_FORBIDDEN'; END IF;
   SELECT * INTO issue FROM public.inventory_receipt_issues WHERE id=p_record_id AND restaurant_id=p_store_id FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
   IF issue.row_version IS DISTINCT FROM p_expected_version OR issue.status<>'open' THEN RAISE EXCEPTION 'PROCUREMENT_STALE_VERSION'; END IF;
   IF p_payload->>'resolution' NOT IN ('additional_delivery','exchange','credit','cancel_remaining') OR p_payload->>'resolution' IS NULL THEN RAISE EXCEPTION 'PROCUREMENT_RESOLUTION_REQUIRED'; END IF;
   -- A completed resolution records the actual follow-up evidence, not a payment or stock adjustment.
   before_state:=to_jsonb(issue);
   UPDATE public.inventory_receipt_issues SET status='resolved',resolution=p_payload->>'resolution',reason=p_payload->>'reason',evidence_reference=p_payload->>'evidence_reference',
     resolved_actor=actor,resolved_at=now(),row_version=row_version+1 WHERE id=issue.id RETURNING to_jsonb(inventory_receipt_issues) INTO result;
 ELSE
   SELECT * INTO po FROM public.inventory_purchase_orders WHERE id=p_record_id AND restaurant_id=p_store_id AND workflow_version=2 FOR UPDATE;
   IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_NOT_FOUND'; END IF;
   IF po.row_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'PROCUREMENT_STALE_VERSION'; END IF;
   before_state:=to_jsonb(po);
   PERFORM set_config('app.procurement_write','true',true);
   IF p_action IN ('cancel_remaining','amend_po') THEN
     IF NOT COALESCE((actor->>'can_office_approve')::boolean,false) THEN RAISE EXCEPTION 'PROCUREMENT_OFFICE_FORBIDDEN'; END IF;
     IF po.status NOT IN ('ordered','partially_received') OR EXISTS(SELECT 1 FROM public.inventory_receipts WHERE purchase_order_id=po.id AND status='draft') THEN RAISE EXCEPTION 'PROCUREMENT_CANCEL_NOT_ALLOWED'; END IF;
     SELECT COALESCE(sum(l.accepted_quantity_base),0) INTO accepted FROM public.inventory_receipt_lines l JOIN public.inventory_receipts r ON r.id=l.receipt_id WHERE r.purchase_order_id=po.id AND r.status='confirmed';
     IF p_action='amend_po' AND accepted>0 THEN RAISE EXCEPTION 'PROCUREMENT_RECEIVED_ORDER_REQUIRES_CREDIT_WORKFLOW'; END IF;
     UPDATE public.inventory_purchase_order_lines l SET cancelled_quantity_base=greatest(0,l.ordered_quantity_base-COALESCE((
       SELECT sum(crl.accepted_quantity_base) FROM public.inventory_receipt_lines crl JOIN public.inventory_receipts r ON r.id=crl.receipt_id WHERE crl.purchase_order_line_id=l.id AND r.status='confirmed'),0))
       WHERE l.purchase_order_id=po.id;
     UPDATE public.inventory_purchase_orders SET status=CASE WHEN accepted=0 THEN 'cancelled' ELSE 'received' END,
       procurement_status=CASE WHEN accepted=0 THEN 'cancelled' ELSE procurement_status END,
       commercial_terms=commercial_terms||jsonb_build_object('cancelled_remainder',jsonb_build_object('reason',p_payload->>'reason','evidence_reference',p_payload->>'evidence_reference','actor',actor,'at',now())),
       row_version=row_version+1,updated_at=now() WHERE id=po.id RETURNING * INTO po;
   ELSE
     IF actor->>'system'<>'pos' OR NOT public.can_verify_inventory_receipt(p_store_id) THEN RAISE EXCEPTION 'PROCUREMENT_RETURN_GOODS_FORBIDDEN'; END IF;
     SELECT l.* INTO rl FROM public.inventory_receipt_lines l JOIN public.inventory_receipts r ON r.id=l.receipt_id WHERE l.id=(p_payload->>'receipt_line_id')::uuid AND r.purchase_order_id=po.id AND r.status='confirmed' FOR UPDATE OF l;
     IF NOT FOUND THEN RAISE EXCEPTION 'PROCUREMENT_RECEIPT_LINE_INVALID'; END IF;
     qty:=(p_payload->>'quantity_base')::numeric;
     SELECT COALESCE(sum(quantity_base),0) INTO already_returned FROM public.inventory_supplier_returns WHERE receipt_line_id=rl.id;
     IF qty IS NULL OR qty<=0 OR qty<>round(qty,3) OR qty::text IN ('NaN','Infinity','-Infinity') OR qty>rl.accepted_quantity_base-already_returned THEN RAISE EXCEPTION 'PROCUREMENT_RETURN_QUANTITY_INVALID'; END IF;
     SELECT * INTO product FROM public.inventory_products WHERE id=rl.product_id AND restaurant_id=p_store_id;
     SELECT current_stock INTO stock FROM public.inventory_items WHERE id=product.inventory_item_id AND restaurant_id=p_store_id FOR UPDATE;
     IF NOT FOUND OR stock<qty THEN RAISE EXCEPTION 'PROCUREMENT_RETURN_STOCK_INSUFFICIENT'; END IF;
     INSERT INTO public.inventory_supplier_returns(restaurant_id,receipt_line_id,purchase_order_id,quantity_base,reason,evidence_reference,actor)
       VALUES(p_store_id,rl.id,po.id,qty,p_payload->>'reason',p_payload->>'evidence_reference',actor) RETURNING to_jsonb(inventory_supplier_returns) INTO result;
     UPDATE public.inventory_items SET current_stock=current_stock-qty,quantity=quantity-qty,updated_at=now() WHERE id=product.inventory_item_id;
     INSERT INTO public.inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,reference_id,note,created_by)
       VALUES(p_store_id,product.inventory_item_id,'deduct',-qty,'inventory_supplier_return',(result->>'id')::uuid,p_payload->>'reason',auth.uid());
     UPDATE public.inventory_purchase_orders SET row_version=row_version+1,updated_at=now() WHERE id=po.id RETURNING * INTO po;
   END IF;
   IF p_action='amend_po' THEN
     SELECT jsonb_build_object('reason',p_payload->>'reason','requested_delivery_date',(p_payload->>'requested_delivery_date')::date,
       'memo','Replacement request for cancelled PO '||po.purchase_order_no,
       'lines',jsonb_agg(jsonb_build_object('product_id',l.product_id,'quantity',l.ordered_quantity_base,'unit',l.base_unit_snapshot,'preferred_supplier_id',po.supplier_id)))
     INTO result FROM public.inventory_purchase_order_lines l WHERE l.purchase_order_id=po.id;
     result:=public.procurement_core_command(p_store_id,'create_request',NULL,0,p_idempotency_key||':replacement',result,p_office_actor);
   END IF;
   result:=to_jsonb(po)||jsonb_build_object('followup',result);
 END IF;
 INSERT INTO public.procurement_events(restaurant_id,record_id,action,actor,previous_state,next_state,reason) VALUES(p_store_id,p_record_id,p_action,actor,before_state,result,p_payload->>'reason');
 INSERT INTO public.procurement_command_results(restaurant_id,idempotency_key,actor_key,payload_hash,result) VALUES(p_store_id,p_idempotency_key,actor_key,input_hash,result);
 PERFORM set_config('app.procurement_write',COALESCE(saved_write,''),true);
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb) TO authenticated,service_role;

ALTER FUNCTION public.procurement_workspace(uuid,uuid,jsonb) RENAME TO procurement_core_workspace;
REVOKE ALL ON FUNCTION public.procurement_core_workspace(uuid,uuid,jsonb) FROM PUBLIC,anon,authenticated,service_role;
CREATE FUNCTION public.procurement_workspace(p_store_id uuid,p_request_id uuid DEFAULT NULL,p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE result jsonb;actor jsonb;prices boolean;
BEGIN
 result:=public.procurement_core_workspace(p_store_id,p_request_id,p_office_actor);actor:=result->'actor';prices:=COALESCE((actor->>'can_view_prices')::boolean,false);
 RETURN result||public.procurement_supplier_evidence(p_store_id,p_office_actor)||jsonb_build_object(
 'demand',public.procurement_demand_evidence(p_store_id,p_office_actor),
 'legacy_terms_review',CASE WHEN prices THEN COALESCE((SELECT jsonb_agg(to_jsonb(po)||jsonb_build_object('lines',(
   SELECT jsonb_agg(to_jsonb(l)||jsonb_build_object('product_name',p.name,'current_base_unit',p.base_unit)) FROM public.inventory_purchase_order_lines l JOIN public.inventory_products p ON p.id=l.product_id WHERE l.purchase_order_id=po.id)))
   FROM public.inventory_purchase_orders po WHERE po.restaurant_id=p_store_id AND po.workflow_version=1 AND po.status IN ('ordered','partially_received','office_approved')
     AND EXISTS(SELECT 1 FROM public.inventory_purchase_order_lines l WHERE l.purchase_order_id=po.id AND (l.order_unit_quantity_base_snapshot IS NULL OR l.tax_rate_snapshot IS NULL))),'[]') ELSE '[]'::jsonb END,
 'issues',COALESCE((SELECT jsonb_agg(to_jsonb(i)) FROM public.inventory_receipt_issues i WHERE restaurant_id=p_store_id),'[]'),
 'returns',COALESCE((SELECT jsonb_agg(to_jsonb(r)) FROM public.inventory_supplier_returns r WHERE restaurant_id=p_store_id),'[]'),
 'receipts',COALESCE((SELECT jsonb_agg((CASE WHEN prices THEN to_jsonb(r) ELSE to_jsonb(r)-'total_supply_amount'-'tax_amount'-'total_amount' END)||jsonb_build_object('lines',(
   SELECT jsonb_agg(CASE WHEN prices THEN to_jsonb(l) ELSE to_jsonb(l)-'actual_unit_price'-'final_supply_amount'-'final_tax_amount' END||jsonb_build_object('product_name',p.name))
   FROM public.inventory_receipt_lines l JOIN public.inventory_products p ON p.id=l.product_id WHERE l.receipt_id=r.id)))
   FROM public.inventory_receipts r JOIN public.inventory_purchase_orders po ON po.id=r.purchase_order_id WHERE r.restaurant_id=p_store_id AND po.workflow_version=2),'[]'));
END $$;
REVOKE ALL ON FUNCTION public.procurement_workspace(uuid,uuid,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.procurement_workspace(uuid,uuid,jsonb) TO authenticated,service_role;
COMMIT;
