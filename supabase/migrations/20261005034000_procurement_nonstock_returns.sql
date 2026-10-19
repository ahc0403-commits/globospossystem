BEGIN;
ALTER TABLE public.inventory_receipt_issues ADD COLUMN followup_reference jsonb;
CREATE OR REPLACE FUNCTION public.procurement_command(p_store_id uuid,p_action text,p_record_id uuid,p_expected_version integer,p_idempotency_key text,p_payload jsonb DEFAULT '{}',p_office_actor jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
DECLARE actor jsonb; prior public.procurement_command_results%rowtype; input_hash text; actor_key text; result jsonb; before_state jsonb;
 po public.inventory_purchase_orders%rowtype; issue public.inventory_receipt_issues%rowtype; rl public.inventory_receipt_lines%rowtype;
 product public.inventory_products%rowtype; followup public.inventory_receipt_lines%rowtype; missing numeric; returned numeric; value_due numeric; qty numeric; already_returned numeric; stock numeric; accepted numeric; saved_write text:=current_setting('app.procurement_write',true);
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
   SELECT * INTO rl FROM public.inventory_receipt_lines WHERE id=issue.receipt_line_id;
   SELECT COALESCE(sum(quantity_base),0) INTO returned FROM public.inventory_supplier_returns WHERE receipt_line_id=rl.id;
   missing:=greatest(issue.ordered_quantity_base-issue.accepted_quantity_base,returned);
   IF p_payload->>'resolution' IN ('additional_delivery','exchange') THEN
     SELECT l.* INTO followup FROM public.inventory_receipt_lines l JOIN public.inventory_receipts r ON r.id=l.receipt_id
       JOIN public.inventory_purchase_orders replacement ON replacement.id=r.purchase_order_id
       JOIN public.inventory_purchase_orders original ON original.id=issue.purchase_order_id
       WHERE l.id=NULLIF(p_payload->>'followup_receipt_line_id','')::uuid AND l.product_id=rl.product_id
         AND r.restaurant_id=p_store_id AND r.status='confirmed' AND r.created_at>=(SELECT created_at FROM public.inventory_receipts WHERE id=rl.receipt_id)
         AND l.id<>rl.id AND replacement.supplier_id=original.supplier_id;
     IF NOT FOUND OR missing<=0 OR followup.accepted_quantity_base-COALESCE((SELECT sum(quantity_base) FROM public.inventory_supplier_returns WHERE receipt_line_id=followup.id),0)<missing
       OR (p_payload->>'resolution'='exchange' AND returned=0 AND rl.rejected_quantity_base=0) THEN RAISE EXCEPTION 'PROCUREMENT_CONFIRMED_FOLLOWUP_REQUIRED'; END IF;
   ELSIF p_payload->>'resolution'='cancel_remaining' THEN
     IF missing<=0 OR NOT EXISTS(SELECT 1 FROM public.inventory_purchase_order_lines l JOIN public.inventory_purchase_orders po ON po.id=l.purchase_order_id
       WHERE l.id=rl.purchase_order_line_id AND l.cancelled_quantity_base>=missing AND po.commercial_terms ? 'cancelled_remainder') THEN RAISE EXCEPTION 'PROCUREMENT_CANCELLED_REMAINDER_REQUIRED'; END IF;
   ELSE
     SELECT greatest(missing,returned)/l.order_unit_quantity_base_snapshot*l.unit_price*(1+l.tax_rate_snapshot/100) INTO value_due
       FROM public.inventory_purchase_order_lines l WHERE l.id=rl.purchase_order_line_id;
     IF auth.role() IS DISTINCT FROM 'service_role' OR actor->>'system'<>'office'
       OR p_payload->'credit_confirmation'->>'purchase_order_id' IS DISTINCT FROM issue.purchase_order_id::text
       OR p_payload->'credit_confirmation'->>'pos_store_id' IS DISTINCT FROM p_store_id::text
       OR p_payload->'credit_confirmation'->>'status' IS DISTINCT FROM 'posted'
       OR NULLIF(p_payload->'credit_confirmation'->>'journal_entry_id','') IS NULL
       OR value_due IS NULL OR value_due<=0 OR COALESCE((p_payload->'credit_confirmation'->>'amount')::numeric,0)<value_due THEN RAISE EXCEPTION 'PROCUREMENT_POSTED_CREDIT_REQUIRED'; END IF;
   END IF;
   before_state:=to_jsonb(issue);
   UPDATE public.inventory_receipt_issues SET status='resolved',resolution=p_payload->>'resolution',reason=p_payload->>'reason',evidence_reference=p_payload->>'evidence_reference',
     followup_reference=CASE WHEN p_payload->>'resolution'='credit' THEN p_payload->'credit_confirmation' ELSE jsonb_build_object('receipt_line_id',followup.id,'purchase_order_id',issue.purchase_order_id,'resolution',p_payload->>'resolution') END,
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
     IF (SELECT receipt_classification_snapshot FROM public.inventory_purchase_order_lines WHERE id=rl.purchase_order_line_id)='stock' THEN
     SELECT current_stock INTO stock FROM public.inventory_items WHERE id=product.inventory_item_id AND restaurant_id=p_store_id FOR UPDATE;
     IF NOT FOUND OR stock<qty THEN RAISE EXCEPTION 'PROCUREMENT_RETURN_STOCK_INSUFFICIENT'; END IF;
     END IF;
     INSERT INTO public.inventory_supplier_returns(restaurant_id,receipt_line_id,purchase_order_id,quantity_base,reason,evidence_reference,actor)
       VALUES(p_store_id,rl.id,po.id,qty,p_payload->>'reason',p_payload->>'evidence_reference',actor) RETURNING to_jsonb(inventory_supplier_returns) INTO result;
     IF (SELECT receipt_classification_snapshot FROM public.inventory_purchase_order_lines WHERE id=rl.purchase_order_line_id)='stock' THEN
     UPDATE public.inventory_items SET current_stock=current_stock-qty,quantity=quantity-qty,updated_at=now() WHERE id=product.inventory_item_id;
     INSERT INTO public.inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,reference_id,note,created_by)
       VALUES(p_store_id,product.inventory_item_id,'deduct',-qty,'inventory_supplier_return',(result->>'id')::uuid,p_payload->>'reason',auth.uid());
     END IF;
     UPDATE public.inventory_purchase_orders SET row_version=row_version+1,updated_at=now() WHERE id=po.id RETURNING * INTO po;
   END IF;
   IF p_action='amend_po' THEN
     SELECT jsonb_build_object('reason',p_payload->>'reason','requested_delivery_date',(p_payload->>'requested_delivery_date')::date,
       'memo','Replacement request for cancelled PO '||po.purchase_order_no,'purchase_category',COALESCE(po.commercial_terms->>'purchase_category','raw_material'),'purchase_channel',COALESCE(po.commercial_terms->>'purchase_channel','ordinary'),
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

COMMIT;
