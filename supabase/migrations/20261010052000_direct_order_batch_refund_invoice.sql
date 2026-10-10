-- All direct-order payment targets are locked/aggregated as one set. No change
-- to process_payment or the asynchronous MISA issuance queue.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
CREATE FUNCTION public.direct_order_refund_payment_batch(p_store_id uuid,p_request_id uuid,p_scope text,p_amount numeric,p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE targets jsonb;original_remaining numeric:=0;v jsonb;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 PERFORM 1 FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF $3 NOT IN ('cancellation','supplemental_delivery','delivery_adjustment') OR $4 IS NULL OR $4<=0
 OR $4<>trunc($4) OR $4::text IN ('NaN','Infinity','-Infinity') OR char_length(btrim(COALESCE($5,''))) NOT BETWEEN 1 AND 200
 THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_AMOUNT_INVALID'; END IF;
 IF $3='delivery_adjustment' THEN original_remaining:=public.direct_order_original_delivery_refund_remaining($2); END IF;
 WITH scope AS(
 SELECT f.payment_id,CASE WHEN $3='delivery_adjustment' THEN original_remaining ELSE f.final_total END cap,
 CASE WHEN $3='delivery_adjustment' THEN 1 ELSE 0 END priority,f.approved_at seq
 FROM public.direct_order_financials f WHERE f.request_id=$2 AND $3<>'supplemental_delivery'
 UNION ALL SELECT c.payment_id,c.amount,CASE WHEN $3='cancellation' THEN 1 ELSE 0 END,c.created_at
 FROM public.direct_order_payment_charges c WHERE c.request_id=$2 AND c.payment_id IS NOT NULL
 AND ($3='cancellation' OR c.kind='delivery'))
 SELECT COALESCE(jsonb_agg(to_jsonb(s)),'[]'::jsonb) INTO targets FROM scope s;
 -- Stable payment lock ordering also serializes generic refund/void calls.
 PERFORM p.id FROM public.payments p JOIN jsonb_to_recordset(targets) s(payment_id uuid) ON s.payment_id=p.id
 WHERE p.restaurant_id=$1 ORDER BY p.id FOR UPDATE OF p;
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(targets) s(payment_id uuid) LEFT JOIN public.payments p ON p.id=s.payment_id
 WHERE p.id IS NULL OR p.restaurant_id<>$1 OR p.is_revenue IS NOT TRUE)
 THEN RAISE EXCEPTION 'PAYMENT_ADJUSTMENT_SERVICE_NOT_ALLOWED'; END IF;
 WITH scope AS MATERIALIZED(SELECT * FROM jsonb_to_recordset(targets) s(payment_id uuid,cap numeric,priority integer,seq timestamptz)),
 prior AS(SELECT a.payment_id,sum(a.amount) adjusted,bool_or(a.adjustment_type='void') voided
 FROM public.payment_adjustments a JOIN scope s ON s.payment_id=a.payment_id GROUP BY a.payment_id),
 tax_jobs AS(SELECT DISTINCT e.order_id FROM public.einvoice_jobs e JOIN public.payments p ON p.order_id=e.order_id JOIN scope s ON s.payment_id=p.id
 WHERE e.status NOT IN ('cancelled','failed_terminal') OR e.lookup_url IS NOT NULL OR e.redinvoice_requested),
 balances AS(SELECT p.*,s.priority,s.seq,COALESCE(a.adjusted,0) adjusted,
 CASE WHEN COALESCE(a.voided,false) THEN 0 ELSE greatest(0,least(CASE WHEN $3='delivery_adjustment' AND s.priority=1 THEN s.cap ELSE s.cap-COALESCE(a.adjusted,0) END,p.amount-COALESCE(a.adjusted,0))) END balance,
 e.order_id IS NOT NULL tax_action
 FROM scope s JOIN public.payments p ON p.id=s.payment_id LEFT JOIN prior a ON a.payment_id=p.id LEFT JOIN tax_jobs e ON e.order_id=p.order_id),
 allocation AS(SELECT b.*,least(balance,greatest(0,$4-COALESCE(sum(balance) OVER
 (ORDER BY priority,CASE WHEN $3='delivery_adjustment' THEN seq END DESC,CASE WHEN $3<>'delivery_adjustment' THEN seq END,id
 ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),0))) part FROM balances b),
 inserted AS(INSERT INTO public.payment_adjustments(payment_id,order_id,restaurant_id,adjustment_type,amount,method,reason,created_by,metadata)
 SELECT id,order_id,restaurant_id,'refund',part,method,btrim($5),auth.uid(),jsonb_build_object('payment_amount',amount,
 'previous_adjusted_amount',adjusted,'remaining_amount_before',amount-adjusted,'wetax_action_required',tax_action)
 FROM allocation WHERE part>0 RETURNING *),
 audit AS(INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
 SELECT auth.uid(),'refund_payment','payment_adjustments',id,jsonb_build_object('payment_id',payment_id,'order_id',order_id,
 'restaurant_id',restaurant_id,'adjustment_type','refund','amount',amount,'method',method,
 'wetax_action_required',metadata->'wetax_action_required') FROM inserted RETURNING id)
 SELECT jsonb_build_object('unposted_amount',$4-COALESCE(sum(amount),0),'adjustment_ids',COALESCE(jsonb_agg(id),'[]'::jsonb)) INTO v FROM inserted;
 RETURN v;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_refund_payment_batch(uuid,uuid,text,numeric,text) FROM PUBLIC,anon,authenticated;

-- Minimal buyer intake contract, but with one payment/item aggregate and one
-- queue/intake update for the entire order set. Existing frozen MISA line items,
-- issued-job manual review, exported-intake locks and tax-entity gates survive.
CREATE FUNCTION public.direct_order_sync_invoice_batch(p_store_id uuid,p_request_id uuid,p_order_ids uuid[] DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE buyer jsonb;actor public.users%ROWTYPE;taxid uuid;taxcode text;config public.meinvoice_tax_entity_config%ROWTYPE;
 ids uuid[];complete boolean;buyer_snapshot jsonb;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT * INTO actor FROM public.users WHERE auth_id=auth.uid() AND is_active LIMIT 1;
 SELECT invoice_details INTO buyer FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF buyer->>'requested' IS DISTINCT FROM 'true' THEN RETURN; END IF;
 SELECT array_agg(DISTINCT order_id) INTO ids FROM(
 SELECT order_id FROM public.direct_order_financials WHERE request_id=$2
 UNION ALL SELECT order_id FROM public.direct_order_payment_charges WHERE request_id=$2 AND order_id IS NOT NULL) s
 WHERE $3 IS NULL OR order_id=ANY($3);
 IF cardinality(ids) IS NULL THEN RETURN; END IF;
 IF EXISTS(SELECT 1 FROM public.restaurants WHERE id=$1 AND brand_id='77000000-0000-0000-0000-000000000001')
 THEN RAISE EXCEPTION 'RED_INVOICE_DISABLED_FOR_PHOTO_OBJET'; END IF;
 SELECT r.tax_entity_id,t.tax_code INTO taxid,taxcode FROM public.restaurants r LEFT JOIN public.tax_entity t ON t.id=r.tax_entity_id WHERE r.id=$1;
 IF taxid IS NULL OR taxcode IS NULL OR taxcode='PLACEHOLDER_DEV_000' THEN RAISE EXCEPTION 'TAX_ENTITY_NOT_READY'; END IF;
 SELECT * INTO config FROM public.meinvoice_tax_entity_config WHERE tax_entity_id=taxid;
 -- The request is locked before its orders/queue rows everywhere in this path.
 PERFORM id FROM public.orders WHERE id=ANY(ids) AND restaurant_id=$1 ORDER BY id FOR UPDATE;
 IF (SELECT count(*) FROM public.orders WHERE id=ANY(ids) AND restaurant_id=$1)<>cardinality(ids) THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
 PERFORM id FROM public.meinvoice_jobs WHERE order_id=ANY(ids) ORDER BY order_id FOR UPDATE;
 PERFORM id FROM public.red_invoice_intakes WHERE order_id=ANY(ids) ORDER BY order_id FOR UPDATE;
 IF actor.role<>'super_admin' AND EXISTS(SELECT 1 FROM public.red_invoice_intakes WHERE order_id=ANY(ids) AND status IN ('exported','completed'))
 THEN RAISE EXCEPTION 'RED_INVOICE_INTAKE_LOCKED'; END IF;
 IF EXISTS(SELECT 1 FROM unnest(ids) i LEFT JOIN public.payments p ON p.order_id=i AND p.restaurant_id=$1 AND p.is_revenue GROUP BY i HAVING count(p.id)=0)
 THEN RAISE EXCEPTION 'PAID_RECEIPT_REQUIRED'; END IF;
 complete:=COALESCE(btrim(buyer->>'legal_name'),'')<>'' AND COALESCE(btrim(buyer->>'tax_code'),'')<>''
 AND COALESCE(btrim(buyer->>'address'),'')<>'' AND COALESCE(buyer->>'email','') LIKE '%@%' AND COALESCE(btrim(buyer->>'phone'),'')<>'';
 buyer_snapshot:=CASE WHEN complete THEN jsonb_build_object('tax_code',btrim(buyer->>'tax_code'),
 'tin_cic_household_head_id',btrim(buyer->>'tax_code'),'unit_name',btrim(buyer->>'legal_name'),
 'address',btrim(buyer->>'address'),'email',btrim(buyer->>'email'),'phone',btrim(buyer->>'phone'),'source','red_invoice_intake')
 ELSE jsonb_build_object('customer_name','Red invoice information pending','source','cashier','source_note','Direct Order') END;
 WITH paid AS MATERIALIZED(SELECT p.order_id,array_agg(p.id::text ORDER BY p.created_at,p.id) receipt_ids,
 min(p.created_at) sale_at,sum(p.amount) gross_amount,array_agg(DISTINCT p.method ORDER BY p.method) methods
 FROM public.payments p WHERE p.order_id=ANY(ids) AND p.restaurant_id=$1 AND p.is_revenue GROUP BY p.order_id),
 labels AS(SELECT paid.*,CASE WHEN cardinality(methods)<>1 THEN COALESCE(config.payment_method_mixed,'Tiền mặt/Thẻ/Ví điện tử')
 WHEN methods[1]='CASH' THEN COALESCE(config.payment_method_cash,'Tiền mặt') WHEN methods[1] IN ('CREDITCARD','ATM')
 THEN COALESCE(config.payment_method_card,'Thẻ quốc tế') ELSE COALESCE(config.payment_method_pay,'Ví điện tử/QR') END method_label FROM paid),
 items AS(SELECT i.order_id,jsonb_agg(jsonb_build_object('order_item_id',i.id,'display_name',COALESCE(NULLIF(i.display_name,''),i.label,'Item'),
 'quantity',i.quantity,'unit_price',i.unit_price,'vat_rate',i.vat_rate,'vat_amount',i.vat_amount,'total_amount_ex_tax',i.total_amount_ex_tax,
 'paying_amount_inc_tax',i.paying_amount_inc_tax) ORDER BY i.created_at,i.id) lines
 FROM public.order_items i WHERE i.order_id=ANY(ids) AND i.status<>'cancelled' GROUP BY i.order_id),
 jobs AS(INSERT INTO public.meinvoice_jobs(order_id,store_id,tax_entity_id,buyer_kind,buyer_snapshot,payment_method_snapshot,status)
 SELECT order_id,$1,taxid,CASE WHEN complete THEN 'registered' ELSE 'manual' END,buyer_snapshot,method_label,'dispatch_paused' FROM labels
 ON CONFLICT(order_id) DO UPDATE SET buyer_kind=EXCLUDED.buyer_kind,buyer_snapshot=EXCLUDED.buyer_snapshot,
 status=CASE WHEN meinvoice_jobs.status IN ('sent_to_misa','sent_to_tax_authority','valid_invoice') THEN 'manual_action_required'
 WHEN meinvoice_jobs.status IN ('pending','pending_manual_config') THEN 'dispatch_paused' ELSE meinvoice_jobs.status END,
 manual_action_type=CASE WHEN meinvoice_jobs.status IN ('sent_to_misa','sent_to_tax_authority','valid_invoice') THEN 'buyer_info_after_issue' ELSE meinvoice_jobs.manual_action_type END,
 manual_action_note=CASE WHEN meinvoice_jobs.status IN ('sent_to_misa','sent_to_tax_authority','valid_invoice') THEN
 'Registered-buyer information arrived after first issuance. Review in MISA before any replacement or adjustment.' ELSE meinvoice_jobs.manual_action_note END,
 updated_at=now() RETURNING *),
 intakes AS(INSERT INTO public.red_invoice_intakes(order_id,store_id,tax_entity_id,meinvoice_job_id,receipt_ids,sale_at,gross_amount,payment_method,
 line_items_snapshot,source,status,buyer_tax_code,buyer_legal_name,buyer_address,buyer_email,buyer_phone,source_note,requested_by,updated_by,ready_at)
 SELECT j.order_id,$1,taxid,j.id,l.receipt_ids,l.sale_at,l.gross_amount,COALESCE(NULLIF(btrim(j.payment_method_snapshot),''),l.method_label),
 CASE WHEN jsonb_array_length(COALESCE(j.line_items_snapshot,'[]'::jsonb))>0 THEN j.line_items_snapshot ELSE COALESCE(i.lines,'[]'::jsonb) END,
 'cashier',CASE WHEN j.manual_action_type='buyer_info_after_issue' AND j.status='manual_action_required' THEN 'manual_review'
 WHEN complete THEN 'ready' ELSE 'awaiting_information' END,NULLIF(btrim(buyer->>'tax_code'),''),NULLIF(btrim(buyer->>'legal_name'),''),
 NULLIF(btrim(buyer->>'address'),''),NULLIF(btrim(buyer->>'email'),''),NULLIF(btrim(buyer->>'phone'),''),'Direct Order',actor.id,actor.id,
 CASE WHEN complete THEN now() END FROM jobs j JOIN labels l ON l.order_id=j.order_id LEFT JOIN items i ON i.order_id=j.order_id
 ON CONFLICT(order_id) DO UPDATE SET source=EXCLUDED.source,status=EXCLUDED.status,buyer_tax_code=EXCLUDED.buyer_tax_code,
 buyer_legal_name=EXCLUDED.buyer_legal_name,buyer_address=EXCLUDED.buyer_address,buyer_email=EXCLUDED.buyer_email,buyer_phone=EXCLUDED.buyer_phone,
 buyer_unit_code=NULL,buyer_full_name=NULL,buyer_email_cc=NULL,buyer_id=NULL,source_note=EXCLUDED.source_note,receipt_ids=EXCLUDED.receipt_ids,
 sale_at=EXCLUDED.sale_at,gross_amount=EXCLUDED.gross_amount,payment_method=EXCLUDED.payment_method,line_items_snapshot=EXCLUDED.line_items_snapshot,
 meinvoice_job_id=EXCLUDED.meinvoice_job_id,updated_by=EXCLUDED.updated_by,updated_at=now(),
 ready_at=CASE WHEN EXCLUDED.status='ready' THEN COALESCE(red_invoice_intakes.ready_at,now()) ELSE red_invoice_intakes.ready_at END RETURNING *)
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
 SELECT auth.uid(),'upsert_red_invoice_intake_minimal','red_invoice_intakes',id,jsonb_build_object('order_id',order_id,'store_id',$1,
 'source','cashier','status',status,'receipt_ids',receipt_ids) FROM intakes;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_sync_invoice_batch(uuid,uuid,uuid[]) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.direct_order_sync_invoice(p_store_id uuid,p_request_id uuid,p_order_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN PERFORM public.direct_order_sync_invoice_batch($1,$2,ARRAY[$3]); END; $$;
REVOKE ALL ON FUNCTION public.direct_order_sync_invoice(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;

DO $patch$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_staff_support_before_cost(uuid,uuid,integer,text,jsonb)'::regprocedure) INTO d;
 IF strpos(d,$old$  IF v_fin.order_id IS NOT NULL THEN PERFORM public.direct_order_sync_invoice(p_store_id,r.id,v_fin.order_id); END IF;
  FOR c IN SELECT * FROM public.direct_order_payment_charges WHERE request_id=r.id AND order_id IS NOT NULL LOOP
   PERFORM public.direct_order_sync_invoice(p_store_id,r.id,c.order_id);
  END LOOP;
$old$)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_BATCH_PATCH_DRIFT'; END IF;
 EXECUTE replace(d,$old$  IF v_fin.order_id IS NOT NULL THEN PERFORM public.direct_order_sync_invoice(p_store_id,r.id,v_fin.order_id); END IF;
  FOR c IN SELECT * FROM public.direct_order_payment_charges WHERE request_id=r.id AND order_id IS NOT NULL LOOP
   PERFORM public.direct_order_sync_invoice(p_store_id,r.id,c.order_id);
  END LOOP;
$old$,$new$  PERFORM public.direct_order_sync_invoice_batch(p_store_id,r.id);
$new$);
 SELECT pg_get_functiondef('public.direct_order_staff_support_before_cost(uuid,uuid,integer,text,jsonb)'::regprocedure) INTO d;
 IF strpos(d,$old$  v_left:=v_amount;
  FOR c IN SELECT * FROM public.direct_order_payment_charges WHERE request_id=r.id AND kind='delivery' AND payment_id IS NOT NULL ORDER BY created_at,id LOOP
   EXIT WHEN v_left<=0;
   SELECT greatest(0,c.amount-COALESCE(sum(amount),0)) INTO v_part FROM public.payment_adjustments WHERE payment_id=c.payment_id;
   v_part:=least(v_left,v_part);
   IF v_part>0 THEN PERFORM public.record_payment_adjustment(c.payment_id,'refund',v_part,p_payload->>'reference'); v_left:=v_left-v_part; END IF;
  END LOOP;
$old$)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_BATCH_PATCH_DRIFT'; END IF;
 EXECUTE replace(d,$old$  v_left:=v_amount;
  FOR c IN SELECT * FROM public.direct_order_payment_charges WHERE request_id=r.id AND kind='delivery' AND payment_id IS NOT NULL ORDER BY created_at,id LOOP
   EXIT WHEN v_left<=0;
   SELECT greatest(0,c.amount-COALESCE(sum(amount),0)) INTO v_part FROM public.payment_adjustments WHERE payment_id=c.payment_id;
   v_part:=least(v_left,v_part);
   IF v_part>0 THEN PERFORM public.record_payment_adjustment(c.payment_id,'refund',v_part,p_payload->>'reference'); v_left:=v_left-v_part; END IF;
  END LOOP;
$old$,$new$  v_left:=(public.direct_order_refund_payment_batch(p_store_id,r.id,'supplemental_delivery',v_amount,p_payload->>'reference')->>'unposted_amount')::numeric;
$new$);
 SELECT pg_get_functiondef('public.direct_order_staff_support_before_cost(uuid,uuid,integer,text,jsonb)'::regprocedure) INTO d;
 IF strpos(d,$old$  v_extra:=least(v_amount,public.direct_order_overpayment_due(r.id));
  v_left:=v_amount-v_extra;
  IF v_fin.payment_id IS NOT NULL THEN
   SELECT greatest(0,v_fin.final_total-COALESCE(sum(amount),0)) INTO v_part FROM public.payment_adjustments WHERE payment_id=v_fin.payment_id;
   v_part:=least(v_left,v_part);
   IF v_part>0 THEN PERFORM public.record_payment_adjustment(v_fin.payment_id,'refund',v_part,p_payload->>'reference'); v_left:=v_left-v_part; END IF;
  END IF;
  FOR c IN SELECT * FROM public.direct_order_payment_charges WHERE request_id=r.id AND payment_id IS NOT NULL ORDER BY created_at,id LOOP
   EXIT WHEN v_left<=0;
   SELECT greatest(0,c.amount-COALESCE(sum(amount),0)) INTO v_part FROM public.payment_adjustments WHERE payment_id=c.payment_id;
   v_part:=least(v_left,v_part);
   IF v_part>0 THEN PERFORM public.record_payment_adjustment(c.payment_id,'refund',v_part,p_payload->>'reference'); v_left:=v_left-v_part; END IF;
  END LOOP;
$old$)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_BATCH_PATCH_DRIFT'; END IF;
 EXECUTE replace(d,$old$  v_extra:=least(v_amount,public.direct_order_overpayment_due(r.id));
  v_left:=v_amount-v_extra;
  IF v_fin.payment_id IS NOT NULL THEN
   SELECT greatest(0,v_fin.final_total-COALESCE(sum(amount),0)) INTO v_part FROM public.payment_adjustments WHERE payment_id=v_fin.payment_id;
   v_part:=least(v_left,v_part);
   IF v_part>0 THEN PERFORM public.record_payment_adjustment(v_fin.payment_id,'refund',v_part,p_payload->>'reference'); v_left:=v_left-v_part; END IF;
  END IF;
  FOR c IN SELECT * FROM public.direct_order_payment_charges WHERE request_id=r.id AND payment_id IS NOT NULL ORDER BY created_at,id LOOP
   EXIT WHEN v_left<=0;
   SELECT greatest(0,c.amount-COALESCE(sum(amount),0)) INTO v_part FROM public.payment_adjustments WHERE payment_id=c.payment_id;
   v_part:=least(v_left,v_part);
   IF v_part>0 THEN PERFORM public.record_payment_adjustment(c.payment_id,'refund',v_part,p_payload->>'reference'); v_left:=v_left-v_part; END IF;
  END LOOP;
$old$,$new$  v_extra:=least(v_amount,public.direct_order_overpayment_due(r.id));
  v_left:=v_amount-v_extra;
  IF v_left>0 THEN v_left:=(public.direct_order_refund_payment_batch(p_store_id,r.id,'cancellation',v_left,p_payload->>'reference')->>'unposted_amount')::numeric; END IF;
$new$);
 SELECT pg_get_functiondef('public.direct_order_staff_support_before_reconciliation(uuid,uuid,integer,text,jsonb)'::regprocedure) INTO d;
 IF strpos(d,$old$  left_amount:=amount;
  -- Refund delivery-only supplemental payments first, then the delivery portion of the original payment.
  FOR c IN SELECT pc.payment_id,pc.amount FROM public.direct_order_payment_charges pc WHERE pc.request_id=r.id AND pc.kind='delivery' AND pc.payment_id IS NOT NULL ORDER BY pc.created_at DESC,pc.id LOOP
   SELECT least(left_amount,greatest(0,c.amount-COALESCE(sum(a.amount),0))) INTO part FROM public.payment_adjustments a WHERE a.payment_id=c.payment_id;
   IF part>0 THEN SELECT id INTO adjustment FROM public.record_payment_adjustment(c.payment_id,'refund',part,p_payload->>'reference'); adjustments:=array_append(adjustments,adjustment); left_amount:=left_amount-part; END IF;
   EXIT WHEN left_amount<=0;
  END LOOP;
  IF left_amount>0 THEN
   SELECT least(left_amount,public.direct_order_original_delivery_refund_remaining(r.id)) INTO part;
   IF part>0 THEN SELECT id INTO adjustment FROM public.record_payment_adjustment(f.payment_id,'refund',part,p_payload->>'reference'); adjustments:=array_append(adjustments,adjustment); left_amount:=left_amount-part; END IF;
  END IF;
$old$)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_BATCH_PATCH_DRIFT'; END IF;
 EXECUTE replace(d,$old$  left_amount:=amount;
  -- Refund delivery-only supplemental payments first, then the delivery portion of the original payment.
  FOR c IN SELECT pc.payment_id,pc.amount FROM public.direct_order_payment_charges pc WHERE pc.request_id=r.id AND pc.kind='delivery' AND pc.payment_id IS NOT NULL ORDER BY pc.created_at DESC,pc.id LOOP
   SELECT least(left_amount,greatest(0,c.amount-COALESCE(sum(a.amount),0))) INTO part FROM public.payment_adjustments a WHERE a.payment_id=c.payment_id;
   IF part>0 THEN SELECT id INTO adjustment FROM public.record_payment_adjustment(c.payment_id,'refund',part,p_payload->>'reference'); adjustments:=array_append(adjustments,adjustment); left_amount:=left_amount-part; END IF;
   EXIT WHEN left_amount<=0;
  END LOOP;
  IF left_amount>0 THEN
   SELECT least(left_amount,public.direct_order_original_delivery_refund_remaining(r.id)) INTO part;
   IF part>0 THEN SELECT id INTO adjustment FROM public.record_payment_adjustment(f.payment_id,'refund',part,p_payload->>'reference'); adjustments:=array_append(adjustments,adjustment); left_amount:=left_amount-part; END IF;
  END IF;
$old$,$new$  balance:=public.direct_order_refund_payment_batch(p_store_id,r.id,'delivery_adjustment',amount,p_payload->>'reference');
  left_amount:=(balance->>'unposted_amount')::numeric;
  SELECT COALESCE(array_agg(value::uuid),'{}'::uuid[]) INTO adjustments FROM jsonb_array_elements_text(balance->'adjustment_ids');
$new$);
END; $patch$;
DO $verify$
BEGIN
 IF has_function_privilege('authenticated','public.direct_order_refund_payment_batch(uuid,uuid,text,numeric,text)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_sync_invoice_batch(uuid,uuid,uuid[])','EXECUTE')
 OR strpos(pg_get_functiondef('public.direct_order_staff_support_before_cost(uuid,uuid,integer,text,jsonb)'::regprocedure),'FOR c IN SELECT')>0
 THEN RAISE EXCEPTION 'DIRECT_ORDER_BATCH_PERMISSION_DRIFT'; END IF;
END; $verify$;
COMMIT;
