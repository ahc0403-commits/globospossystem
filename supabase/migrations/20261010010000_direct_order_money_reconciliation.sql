-- Actual bank receipts, refund evidence, and immutable driver cash movements.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
ALTER TABLE public.direct_order_payment_receipts ADD COLUMN actual_amount numeric(15,2);
UPDATE public.direct_order_payment_receipts SET actual_amount=amount;
ALTER TABLE public.direct_order_payment_receipts ALTER COLUMN actual_amount SET NOT NULL;
ALTER TABLE public.direct_order_payment_receipts DROP CONSTRAINT direct_order_payment_receipts_amount_check;
ALTER TABLE public.direct_order_payment_receipts ADD CONSTRAINT direct_order_receipt_amounts CHECK(
 amount::text<>'NaN' AND actual_amount::text<>'NaN' AND amount>=0 AND amount=trunc(amount) AND actual_amount>0 AND actual_amount=trunc(actual_amount) AND actual_amount>=amount);
CREATE FUNCTION public.direct_order_fill_actual_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.actual_amount:=COALESCE(NEW.actual_amount,NEW.amount); RETURN NEW; END; $$;
CREATE TRIGGER direct_order_fill_actual_receipt BEFORE INSERT ON public.direct_order_payment_receipts
 FOR EACH ROW EXECUTE FUNCTION public.direct_order_fill_actual_receipt();
ALTER TABLE public.direct_order_refund_records ADD COLUMN overpayment_amount numeric(15,2) NOT NULL DEFAULT 0 CHECK(overpayment_amount>=0 AND overpayment_amount<=unposted_amount);
ALTER TABLE public.direct_order_refund_records DROP CONSTRAINT direct_order_refund_records_purpose_check;
ALTER TABLE public.direct_order_refund_records ADD CONSTRAINT direct_order_refund_records_purpose_check CHECK(purpose IN ('cancellation','pickup_delivery','delivery_adjustment','overpayment'));
CREATE TABLE public.direct_order_refund_evidence(
 refund_id uuid PRIMARY KEY REFERENCES public.direct_order_refund_records(id),
 request_id uuid NOT NULL REFERENCES public.direct_order_requests(id),restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 evidence_message_id uuid NOT NULL REFERENCES public.direct_order_messages(id),
 method text NOT NULL CHECK(method IN ('BANKTRANSFER','CASH')),
 recorded_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.direct_order_refund_evidence ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.direct_order_refund_evidence FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.direct_order_refund_evidence TO service_role;
CREATE FUNCTION public.direct_order_overpayment_due(p_request_id uuid) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT greatest(0,COALESCE((SELECT sum(actual_amount-amount) FROM public.direct_order_payment_receipts WHERE request_id=$1),0)
 -COALESCE((SELECT sum(overpayment_amount) FROM public.direct_order_refund_records WHERE request_id=$1),0)); $$;
REVOKE ALL ON FUNCTION public.direct_order_overpayment_due(uuid) FROM PUBLIC,anon,authenticated;
CREATE OR REPLACE FUNCTION public.direct_order_refund_balance(p_request_id uuid)
RETURNS TABLE(received numeric,refunded numeric) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH f AS (SELECT * FROM public.direct_order_financials WHERE request_id=$1),
 receipts AS (SELECT COALESCE(sum(x.amount) FILTER(WHERE c.kind IS DISTINCT FROM 'delivery'),0) food,
 COALESCE(sum(x.amount) FILTER(WHERE c.kind='delivery'),0) delivery,COALESCE(sum(x.actual_amount-x.amount),0) extra
 FROM public.direct_order_payment_receipts x LEFT JOIN public.direct_order_payment_charges c ON c.id=x.charge_id WHERE x.request_id=$1),
 payments AS (SELECT payment_id FROM f UNION SELECT payment_id FROM public.direct_order_payment_charges WHERE request_id=$1 AND payment_id IS NOT NULL)
 SELECT COALESCE((SELECT final_total FROM f),r.food)+r.delivery+r.extra,
 COALESCE((SELECT sum(a.amount) FROM public.payment_adjustments a JOIN payments p ON p.payment_id=a.payment_id),0)
 +COALESCE((SELECT sum(unposted_amount) FROM public.direct_order_refund_records WHERE request_id=$1),0) FROM receipts r; $$;
CREATE OR REPLACE FUNCTION public.direct_order_record_receipt(p_store_id uuid,p_request_id uuid,p_quote_id uuid,p_proof_message_id uuid,p_amount numeric,p_bank_reference text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE r public.direct_order_requests%ROWTYPE; q public.direct_order_quotes%ROWTYPE;
 m public.direct_order_messages%ROWTYPE; c public.direct_order_payment_charges%ROWTYPE;
 v_existing public.direct_order_payment_receipts%ROWTYPE; v_total numeric; v_due numeric; v_result jsonb;
 v_applied numeric; v_order public.orders%ROWTYPE; v_payment public.payments%ROWTYPE; v_fee_pretax numeric; v_vat numeric; v_rate numeric;
BEGIN
 PERFORM public.direct_order_require_actor(p_store_id,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 PERFORM pg_advisory_xact_lock(hashtextextended('direct-order-approval:'||p_request_id::text,0));
 SELECT * INTO r FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 SELECT * INTO v_existing FROM public.direct_order_payment_receipts WHERE proof_message_id=p_proof_message_id;
 IF FOUND THEN
  IF v_existing.request_id<>r.id OR v_existing.actual_amount IS DISTINCT FROM p_amount OR v_existing.quote_id IS DISTINCT FROM p_quote_id OR v_existing.bank_reference IS DISTINCT FROM btrim(p_bank_reference) THEN
   RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED'; END IF;
  RETURN public.direct_order_support_context(r.id,true);
 END IF;
 IF r.state IN ('cancelled','rejected','expired') OR p_amount IS NULL OR p_amount<=0 OR p_amount<>trunc(p_amount) OR p_amount::text IN ('NaN','Infinity','-Infinity')
  OR char_length(btrim(COALESCE(p_bank_reference,''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'DIRECT_ORDER_RECEIPT_INVALID'; END IF;
 SELECT * INTO q FROM public.direct_order_quotes WHERE id=p_quote_id AND request_id=r.id AND status='locked' FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_CHANGED'; END IF;
 SELECT * INTO m FROM public.direct_order_messages WHERE id=p_proof_message_id AND request_id=r.id AND restaurant_id=p_store_id
  AND message_type='payment_proof' AND sender_type='customer' AND attachment_storage_path IS NOT NULL;
 IF NOT FOUND OR m.metadata->>'quote_id' IS DISTINCT FROM q.id::text THEN RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_PROOF_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM public.direct_order_proof_review_requests WHERE request_id=r.id AND status='requested') THEN
  RAISE EXCEPTION 'DIRECT_ORDER_PROOF_RESUBMISSION_PENDING'; END IF;
 IF m.metadata->>'charge_id' IS NOT NULL THEN
  SELECT * INTO c FROM public.direct_order_payment_charges WHERE id=(m.metadata->>'charge_id')::uuid AND request_id=r.id FOR UPDATE;
  IF NOT FOUND OR c.status NOT IN ('pending','review') THEN RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;
 END IF;
 IF m.id IS DISTINCT FROM (SELECT x.id FROM public.direct_order_messages x WHERE x.request_id=r.id AND x.message_type='payment_proof'
  AND x.metadata->>'quote_id'=q.id::text AND x.metadata->>'charge_id' IS NOT DISTINCT FROM m.metadata->>'charge_id'
  ORDER BY x.created_at DESC,x.id DESC LIMIT 1) THEN RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED'; END IF;
 IF c.kind='delivery' THEN
  SELECT c.amount-COALESCE(sum(amount),0) INTO v_due FROM public.direct_order_payment_receipts WHERE charge_id=c.id;
 ELSE
  IF EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=r.id) THEN v_due:=0; ELSE
  SELECT q.final_total-COALESCE(sum(x.amount),0) INTO v_due FROM public.direct_order_payment_receipts x
   LEFT JOIN public.direct_order_payment_charges z ON z.id=x.charge_id WHERE x.request_id=r.id AND z.kind IS DISTINCT FROM 'delivery'; END IF;
 END IF;
 IF EXISTS(SELECT 1 FROM public.direct_order_payment_receipts WHERE request_id=r.id AND bank_reference=btrim(p_bank_reference)) THEN RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED'; END IF;
 v_applied:=least(p_amount,greatest(0,v_due));
 INSERT INTO public.direct_order_payment_receipts(request_id,restaurant_id,charge_id,quote_id,proof_message_id,amount,actual_amount,bank_reference,confirmed_by)
 VALUES(r.id,p_store_id,c.id,q.id,m.id,v_applied,p_amount,btrim(p_bank_reference),auth.uid());
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'direct_order_receipt_confirmed','direct_order_requests',r.id,
  jsonb_build_object('actual_amount',p_amount,'applied_amount',v_applied,'proof_message_id',m.id,'charge_id',c.id,'actual_bank_receipt_confirmed',true));
 IF c.kind='delivery' AND v_applied>0 AND v_applied=v_due THEN
  SELECT delivery_fee_vat_rate INTO v_rate FROM public.direct_order_storefronts WHERE restaurant_id=p_store_id;
  v_fee_pretax:=round(c.amount/(1+v_rate/100),2); v_vat:=c.amount-v_fee_pretax;
  -- A supplemental service-only financial order never contains food or inventory.
  INSERT INTO public.orders(restaurant_id,table_id,sales_channel,status,guest_count,created_by,notes,order_source,order_purpose,fulfillment_mode_snapshot)
  VALUES(p_store_id,NULL,'delivery','serving',NULL,auth.uid(),'Direct delivery fee '||r.reference_code,'staff','customer','pos_print') RETURNING * INTO v_order;
  INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,item_type,label,display_name,unit_price,quantity,status,
   vat_rate,vat_amount,total_amount_ex_tax,paying_amount_inc_tax,is_service_item,fulfillment_mode_snapshot)
  VALUES(p_store_id,v_order.id,NULL,'service_charge','Phí giao hàng','Phí giao hàng',v_fee_pretax,1,'served',
   v_rate,v_vat,v_fee_pretax,c.amount,false,'pos_print');
  v_payment:=public.process_payment(v_order.id,p_store_id,c.amount,'BANKTRANSFER');
  IF v_payment.amount_portion IS DISTINCT FROM c.amount THEN RAISE EXCEPTION 'DIRECT_ORDER_FINANCIAL_RECONCILIATION_FAILED'; END IF;
  UPDATE public.direct_order_payment_charges SET status='paid',order_id=v_order.id,payment_id=v_payment.id WHERE id=c.id;
  PERFORM public.direct_order_sync_invoice(p_store_id,r.id,v_order.id);
 ELSIF c.kind IS DISTINCT FROM 'delivery' AND v_applied>0 AND v_applied=v_due THEN
  v_result:=public.direct_order_approve_photo_payment(p_store_id,r.id,q.final_total,q.id,m.id);
  UPDATE public.direct_order_payment_charges SET status='paid' WHERE request_id=r.id AND kind='food_balance' AND status<>'void';
  PERFORM public.direct_order_sync_invoice(p_store_id,r.id,(v_result->>'order_id')::uuid);
 ELSIF c.id IS NOT NULL THEN
  UPDATE public.direct_order_payment_charges SET status='pending' WHERE id=c.id;
 END IF;
 UPDATE public.direct_order_requests SET support_version=support_version+1 WHERE id=r.id;
 RETURN public.direct_order_support_context(r.id,true);
END;
$$;

-- Cancellation refunds return unallocated money before reversing order revenue.
DO $refund_allocation$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_staff_support_before_cost(uuid,uuid,integer,text,jsonb)'::regprocedure) INTO d;
 IF strpos(d,'v_part numeric;')=0 OR strpos(d,$anchor$ELSIF p_action='refund_complete' THEN$anchor$)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_ANCHOR_DRIFT'; END IF;
 d:=replace(d,'v_part numeric;','v_part numeric; v_extra numeric;');
 -- The last v_left assignment belongs to cancellation; earlier shipping branches stay unchanged.
 d:=replace(d,E'  v_left:=v_amount;
  IF v_fin.payment_id',E'  v_extra:=least(v_amount,public.direct_order_overpayment_due(r.id));
  v_left:=v_amount-v_extra;
  IF v_fin.payment_id');
 d:=replace(d,'amount,unposted_amount,reference,recorded_by)','amount,unposted_amount,overpayment_amount,reference,recorded_by)');
 d:=replace(d,$anchor$r.id,p_store_id,v_amount,v_left,btrim(p_payload->>'reference'),auth.uid());$anchor$, $anchor$r.id,p_store_id,v_amount,v_left+v_extra,v_extra,btrim(p_payload->>'reference'),auth.uid());$anchor$);
 IF strpos(d,'v_left:=v_amount-v_extra;')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_ANCHOR_DRIFT'; END IF;
 EXECUTE d;
 -- Extra money refunded must not consume a food/shipping advance.
 SELECT pg_get_functiondef('public.direct_order_post_delivery_advance(uuid,uuid)'::regprocedure) INTO d;
 EXECUTE replace(d,'sum(unposted_amount)','sum(unposted_amount-overpayment_amount)');
 SELECT pg_get_functiondef('public.direct_order_support_context_before_cost(uuid,boolean)'::regprocedure) INTO d;
 EXECUTE replace(d,'sum(unposted_amount)','sum(unposted_amount-overpayment_amount)');
END; $refund_allocation$;
-- Include original pickup adjustments when calculating the remaining refund.
CREATE OR REPLACE FUNCTION public.direct_order_original_delivery_refund_remaining(p_request_id uuid) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT greatest(0,f.delivery_fee_total-COALESCE((SELECT sum(a.amount) FROM public.payment_adjustments a
 WHERE a.payment_id=f.payment_id AND a.id IN (
 SELECT unnest(x.delivery_adjustment_ids) FROM public.direct_order_refund_records x WHERE x.request_id=$1 AND x.purpose='delivery_adjustment'
 UNION SELECT o.adjustment_id FROM public.direct_order_pickup_offers o WHERE o.request_id=$1 AND o.adjustment_id IS NOT NULL)),0))
 FROM public.direct_order_financials f WHERE f.request_id=$1;
$$;
CREATE FUNCTION public.direct_order_require_evidence(p_store_id uuid,p_request_id uuid,p_message_id uuid,p_image_only boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_messages WHERE id=$3 AND restaurant_id=$1 AND request_id=$2
 AND sender_type='cashier' AND message_type='attachment' AND attachment_storage_path IS NOT NULL
 AND (NOT $4 OR attachment_storage_path ~ '[.](jpg|jpeg|png|webp)$')) THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_EVIDENCE_REQUIRED'; END IF;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_require_evidence(uuid,uuid,uuid,boolean) FROM PUBLIC,anon,authenticated;
ALTER FUNCTION public.direct_order_staff_support_action(uuid,uuid,integer,text,jsonb) RENAME TO direct_order_staff_support_before_reconciliation;
REVOKE ALL ON FUNCTION public.direct_order_staff_support_before_reconciliation(uuid,uuid,integer,text,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_staff_support_action(p_store_id uuid,p_request_id uuid,p_expected_version integer,p_action text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE r public.direct_order_requests%ROWTYPE; x public.direct_order_refund_records%ROWTYPE;
 evidence public.direct_order_refund_evidence%ROWTYPE; op uuid; proof uuid; method text; amount numeric; old_due numeric;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_INPUT_INVALID'; END IF;
 IF p_action='refund_details' THEN
  IF r.support_version IS DISTINCT FROM $3 OR r.support_closed_at IS NOT NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_CHANGED'; END IF;
  IF r.state NOT IN ('cancelled','rejected','expired') AND public.direct_order_overpayment_due(r.id)<=0
   AND (public.direct_order_delivery_cost_balance(r.id)->>'refund_due')::numeric<=0
   AND NOT (r.fulfillment_method='pickup' AND public.direct_order_original_delivery_refund_remaining(r.id)>0)
   THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_NOT_ALLOWED'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) k WHERE k NOT IN ('bank','account','holder','note'))
   OR EXISTS(SELECT 1 FROM jsonb_each(p_payload) e WHERE jsonb_typeof(e.value)<>'string')
   OR char_length(COALESCE(p_payload->>'bank','')) NOT BETWEEN 1 AND 100
   OR char_length(COALESCE(p_payload->>'account','')) NOT BETWEEN 1 AND 100
   OR char_length(COALESCE(p_payload->>'holder','')) NOT BETWEEN 1 AND 200
   OR char_length(COALESCE(p_payload->>'note',''))>500 THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_INPUT_INVALID'; END IF;
  UPDATE public.direct_order_requests SET refund_details=p_payload||jsonb_build_object('status','pending'),support_version=support_version+1 WHERE id=r.id;
  RETURN public.direct_order_support_context(r.id,true);
 END IF;
 IF p_action='charge' AND p_payload->>'kind'='food_balance' AND (p_payload->>'amount')::numeric IS DISTINCT FROM (public.direct_order_support_context(r.id,true)->>'food_due')::numeric THEN RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_AMOUNT_INVALID'; END IF;
 IF p_action NOT IN ('refund_overpayment','refund_complete','refund_delivery_complete','refund_delivery_adjustment','refund_original_pickup') THEN
  RETURN public.direct_order_staff_support_before_reconciliation($1,$2,$3,$4,$5);
 END IF;
 op:=(p_payload->>'operation_id')::uuid;proof:=(p_payload->>'evidence_message_id')::uuid;
 method:=p_payload->>'method';amount:=(p_payload->>'amount')::numeric;
 IF op IS NULL OR method IS NULL OR method NOT IN ('CASH','BANKTRANSFER') OR amount IS NULL OR amount<=0 OR amount<>trunc(amount)
 OR amount::text IN ('NaN','Infinity','-Infinity') OR char_length(btrim(COALESCE(p_payload->>'reference',''))) NOT BETWEEN 1 AND 200
 THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_AMOUNT_INVALID'; END IF;
 PERFORM public.direct_order_require_evidence($1,$2,proof);
 SELECT * INTO x FROM public.direct_order_refund_records WHERE id=op;
 IF FOUND THEN
  SELECT * INTO evidence FROM public.direct_order_refund_evidence WHERE refund_id=op;
  IF x.request_id<>r.id OR x.amount<>amount OR x.reference IS DISTINCT FROM btrim(p_payload->>'reference')
   OR x.purpose IS DISTINCT FROM (CASE p_action WHEN 'refund_overpayment' THEN 'overpayment' WHEN 'refund_delivery_adjustment' THEN 'delivery_adjustment'
    WHEN 'refund_complete' THEN 'cancellation' ELSE 'pickup_delivery' END)
   OR evidence.evidence_message_id IS DISTINCT FROM proof OR evidence.method IS DISTINCT FROM method THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_CHANGED'; END IF;
  RETURN public.direct_order_support_context(r.id,true);
 END IF;
 IF r.support_version IS DISTINCT FROM $3 OR r.support_closed_at IS NOT NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_CHANGED'; END IF;
 IF p_action='refund_overpayment' THEN
  IF amount>public.direct_order_overpayment_due(r.id) THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_AMOUNT_INVALID'; END IF;
  INSERT INTO public.direct_order_refund_records(id,request_id,restaurant_id,amount,unposted_amount,overpayment_amount,purpose,reference,recorded_by)
   VALUES(op,r.id,$1,amount,amount,amount,'overpayment',btrim(p_payload->>'reference'),auth.uid());
  UPDATE public.direct_order_requests SET support_version=support_version+1 WHERE id=r.id;
 ELSIF p_action='refund_original_pickup' THEN
  IF NOT EXISTS(SELECT 1 FROM public.direct_order_pickup_offers WHERE id=(p_payload->>'offer_id')::uuid AND request_id=r.id AND status='accepted' AND adjustment_id IS NULL) THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_NOT_DUE'; END IF;
  old_due:=public.direct_order_original_delivery_refund_remaining(r.id);
  IF amount IS DISTINCT FROM old_due THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_AMOUNT_INVALID'; END IF;
  PERFORM public.direct_order_staff_record_pickup_refund($1,$2,(p_payload->>'offer_id')::uuid,p_payload->>'reference');
  INSERT INTO public.direct_order_refund_records(id,request_id,restaurant_id,amount,unposted_amount,purpose,reference,recorded_by)
   VALUES(op,r.id,$1,amount,0,'pickup_delivery',btrim(p_payload->>'reference'),auth.uid());
  UPDATE public.direct_order_requests SET support_version=support_version+1 WHERE id=r.id;
 ELSE
  PERFORM public.direct_order_staff_support_before_reconciliation($1,$2,$3,$4,$5);
 END IF;
 INSERT INTO public.direct_order_refund_evidence VALUES(op,r.id,$1,proof,method,now());
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,metadata)
 VALUES(r.id,$1,'system','system','DIRECT_ORDER_REFUND_RECORDED',jsonb_build_object('amount',amount,'method',method,'evidence_message_id',proof));
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'direct_order_refund_verified','direct_order_requests',r.id,
 jsonb_build_object('operation_id',op,'amount',amount,'method',method,'evidence_message_id',proof));
 RETURN public.direct_order_support_context(r.id,true);
END; $$;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_support_action(uuid,uuid,integer,text,jsonb) TO authenticated,service_role;
REVOKE ALL ON FUNCTION public.direct_order_staff_support_action(uuid,uuid,integer,text,jsonb) FROM PUBLIC,anon;
REVOKE ALL ON FUNCTION public.direct_order_staff_record_pickup_refund(uuid,uuid,uuid,text) FROM authenticated;

CREATE TABLE public.direct_order_driver_cash_movements(
 id uuid PRIMARY KEY,request_id uuid NOT NULL REFERENCES public.direct_order_requests(id),restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 kind text NOT NULL CHECK(kind IN ('payout','recovery')),method text NOT NULL CHECK(method IN ('CASH','BANKTRANSFER')),
 amount numeric(15,2) NOT NULL CHECK(amount>0 AND amount=trunc(amount)),
 reason text NOT NULL CHECK(reason IN ('handoff','correction','recovery')),reference text NOT NULL CHECK(char_length(reference) BETWEEN 1 AND 200),
 parent_id uuid REFERENCES public.direct_order_driver_cash_movements(id),evidence_message_id uuid REFERENCES public.direct_order_messages(id),
 recorded_by uuid REFERENCES auth.users(id),occurred_at timestamptz NOT NULL DEFAULT now(),legacy boolean NOT NULL DEFAULT false,
 CHECK(kind<>'payout' OR method='CASH'),CHECK(legacy OR evidence_message_id IS NOT NULL),CHECK((kind='recovery')=(parent_id IS NOT NULL)));
CREATE UNIQUE INDEX direct_order_driver_one_handoff_payout ON public.direct_order_driver_cash_movements(request_id) WHERE reason='handoff';
CREATE INDEX direct_order_driver_cash_store_time ON public.direct_order_driver_cash_movements(restaurant_id,occurred_at);
ALTER TABLE public.direct_order_driver_cash_movements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.direct_order_driver_cash_movements FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.direct_order_driver_cash_movements TO service_role;
INSERT INTO public.direct_order_driver_cash_movements(id,request_id,restaurant_id,kind,method,amount,reason,reference,recorded_by,occurred_at,legacy)
 SELECT gen_random_uuid(),request_id,restaurant_id,'payout','CASH',actual_grab_fee,'handoff','Legacy dispatch cash payout',sent_by,cash_paid_at,true
 FROM public.direct_order_dispatches WHERE actual_grab_fee>0 AND cash_paid_at IS NOT NULL;
CREATE FUNCTION public.direct_order_money_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'DIRECT_ORDER_MONEY_IMMUTABLE'; END; $$;
CREATE TRIGGER direct_order_driver_cash_immutable BEFORE UPDATE OR DELETE ON public.direct_order_driver_cash_movements FOR EACH ROW EXECUTE FUNCTION public.direct_order_money_immutable();
CREATE TRIGGER direct_order_receipt_immutable BEFORE UPDATE OR DELETE ON public.direct_order_payment_receipts FOR EACH ROW EXECUTE FUNCTION public.direct_order_money_immutable();
CREATE TRIGGER direct_order_refund_evidence_immutable BEFORE UPDATE OR DELETE ON public.direct_order_refund_evidence FOR EACH ROW EXECUTE FUNCTION public.direct_order_money_immutable();
CREATE FUNCTION public.direct_order_cash_payout_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF TG_OP='UPDATE' THEN
  IF NEW.actual_grab_fee IS DISTINCT FROM OLD.actual_grab_fee OR NEW.cash_paid_at IS DISTINCT FROM OLD.cash_paid_at OR NEW.delivery_payment_mode IS DISTINCT FROM OLD.delivery_payment_mode THEN RAISE EXCEPTION 'DIRECT_ORDER_CASH_PAYOUT_LOCKED'; END IF;
  RETURN NEW;
 END IF;
 IF NEW.actual_grab_fee>0 AND current_setting('direct_order.cash_payout_verified',true) IS DISTINCT FROM NEW.request_id::text THEN
  RAISE EXCEPTION 'DIRECT_ORDER_CASH_PAYOUT_CONFIRMATION_REQUIRED'; END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER direct_order_cash_payout_guard BEFORE INSERT OR UPDATE ON public.direct_order_dispatches FOR EACH ROW EXECUTE FUNCTION public.direct_order_cash_payout_guard();
CREATE FUNCTION public.direct_order_set_dispatch_v4(
 p_store_id uuid,p_request_id uuid,p_expected_version integer,p_provider text,
 p_tracking_url text DEFAULT NULL,p_actual_fee numeric DEFAULT NULL,p_provider_name text DEFAULT NULL,p_driver_contact text DEFAULT NULL,
 p_cash_confirmed boolean DEFAULT false,p_evidence_message_id uuid DEFAULT NULL,p_operation_id uuid DEFAULT NULL,p_cash_reference text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE existing public.direct_order_driver_cash_movements%ROWTYPE; result jsonb;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 PERFORM 1 FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF p_actual_fee>0 THEN
  IF p_cash_confirmed IS DISTINCT FROM true OR p_operation_id IS NULL OR char_length(btrim(COALESCE(p_cash_reference,''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'DIRECT_ORDER_CASH_PAYOUT_CONFIRMATION_REQUIRED'; END IF;
  PERFORM public.direct_order_require_evidence($1,$2,p_evidence_message_id,false);
  SELECT * INTO existing FROM public.direct_order_driver_cash_movements WHERE id=p_operation_id;
  IF FOUND AND (existing.request_id<>$2 OR existing.amount IS DISTINCT FROM p_actual_fee OR existing.reason<>'handoff'
   OR existing.evidence_message_id IS DISTINCT FROM p_evidence_message_id OR existing.reference IS DISTINCT FROM btrim(p_cash_reference)) THEN RAISE EXCEPTION 'DIRECT_ORDER_CASH_PAYOUT_LOCKED'; END IF;
  IF NOT FOUND AND EXISTS(SELECT 1 FROM public.direct_order_dispatches WHERE request_id=$2) THEN RAISE EXCEPTION 'DIRECT_ORDER_CASH_PAYOUT_LOCKED'; END IF;
 END IF;
 PERFORM set_config('direct_order.cash_payout_verified',$2::text,true);
 result:=public.direct_order_set_dispatch_v3($1,$2,$3,$4,$5,$6,$7,$8);
 PERFORM set_config('direct_order.cash_payout_verified','',true);
 IF p_actual_fee>0 AND existing.id IS NULL THEN
  INSERT INTO public.direct_order_driver_cash_movements(id,request_id,restaurant_id,kind,method,amount,reason,reference,evidence_message_id,recorded_by)
  VALUES(p_operation_id,$2,$1,'payout','CASH',p_actual_fee,'handoff',btrim(p_cash_reference),p_evidence_message_id,auth.uid());
 END IF;
 RETURN result;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_set_dispatch_v4(uuid,uuid,integer,text,text,numeric,text,text,boolean,uuid,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_set_dispatch_v4(uuid,uuid,integer,text,text,numeric,text,text,boolean,uuid,uuid,text) TO authenticated,service_role;
CREATE FUNCTION public.direct_order_staff_driver_cash_action(p_store_id uuid,p_request_id uuid,p_operation_id uuid,p_kind text,p_amount numeric,p_reference text,p_evidence_message_id uuid,p_parent_id uuid DEFAULT NULL,p_method text DEFAULT 'CASH')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE existing public.direct_order_driver_cash_movements%ROWTYPE; parent public.direct_order_driver_cash_movements%ROWTYPE; returned numeric;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['admin','store_admin','brand_admin','super_admin']);
 PERFORM 1 FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND OR $3 IS NULL OR $4 IS NULL OR $4 NOT IN ('payout','recovery') OR $5 IS NULL OR $5<=0 OR $5<>trunc($5)
 OR $5::text IN ('NaN','Infinity','-Infinity') OR char_length(btrim(COALESCE($6,''))) NOT BETWEEN 1 AND 200
 OR $9 IS NULL OR $9 NOT IN ('CASH','BANKTRANSFER') OR ($4='payout' AND ($8 IS NOT NULL OR $9<>'CASH')) THEN RAISE EXCEPTION 'DIRECT_ORDER_CASH_MOVEMENT_INVALID'; END IF;
 PERFORM public.direct_order_require_evidence($1,$2,$7,false);
 SELECT * INTO existing FROM public.direct_order_driver_cash_movements WHERE id=$3;
 IF FOUND THEN
  IF existing.request_id<>$2 OR existing.kind IS DISTINCT FROM $4 OR existing.amount IS DISTINCT FROM $5 OR existing.reference IS DISTINCT FROM btrim($6)
   OR existing.evidence_message_id IS DISTINCT FROM $7 OR existing.parent_id IS DISTINCT FROM $8 OR existing.method IS DISTINCT FROM $9 THEN RAISE EXCEPTION 'DIRECT_ORDER_CASH_PAYOUT_LOCKED'; END IF;
  RETURN public.direct_order_support_context($2,true);
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_dispatches WHERE request_id=$2 AND delivery_payment_mode='store_prepaid') THEN RAISE EXCEPTION 'DIRECT_ORDER_CASH_MOVEMENT_INVALID'; END IF;
 IF $4='recovery' THEN
  SELECT * INTO parent FROM public.direct_order_driver_cash_movements WHERE id=$8 AND request_id=$2 AND kind='payout' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_CASH_MOVEMENT_INVALID'; END IF;
  SELECT COALESCE(sum(amount),0) INTO returned FROM public.direct_order_driver_cash_movements WHERE parent_id=$8;
  IF $5>parent.amount-returned THEN RAISE EXCEPTION 'DIRECT_ORDER_CASH_MOVEMENT_INVALID'; END IF;
 END IF;
 INSERT INTO public.direct_order_driver_cash_movements(id,request_id,restaurant_id,kind,method,amount,reason,reference,parent_id,evidence_message_id,recorded_by)
 VALUES($3,$2,$1,$4,$9,$5,CASE WHEN $4='payout' THEN 'correction' ELSE 'recovery' END,btrim($6),$8,$7,auth.uid());
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'direct_order_driver_cash_'||$4,'direct_order_requests',$2,
 jsonb_build_object('operation_id',$3,'amount',$5,'method',$9,'parent_id',$8,'evidence_message_id',$7));
 RETURN public.direct_order_support_context($2,true);
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_driver_cash_action(uuid,uuid,uuid,text,numeric,text,uuid,uuid,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_driver_cash_action(uuid,uuid,uuid,text,numeric,text,uuid,uuid,text) TO authenticated,service_role;

ALTER FUNCTION public.direct_order_support_context(uuid,boolean) RENAME TO direct_order_support_context_before_reconciliation;
REVOKE ALL ON FUNCTION public.direct_order_support_context_before_reconciliation(uuid,boolean) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_support_context(p_request_id uuid,p_staff boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT public.direct_order_support_context_before_reconciliation($1,$2)||jsonb_build_object(
 'actual_received',b.received,'overpayment_due',public.direct_order_overpayment_due($1),
 'overpayment_total',COALESCE((SELECT sum(actual_amount-amount) FROM public.direct_order_payment_receipts WHERE request_id=$1),0),
 'refund_account',r.refund_details-ARRAY['note','status'],
 'refund_evidence_available',EXISTS(SELECT 1 FROM public.direct_order_refund_records x JOIN public.direct_order_requests r ON r.id=x.request_id
  WHERE x.request_id=$1 AND x.recorded_at>now()-interval '7 days' AND r.support_closed_at IS NULL AND r.pii_purged_at IS NULL),
 'refunds',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',x.id,'amount',x.amount,'purpose',x.purpose,'method',e.method,
 'evidence_message_id',e.evidence_message_id,'recorded_at',x.recorded_at) ORDER BY x.recorded_at,x.id)
 FROM public.direct_order_refund_records x LEFT JOIN public.direct_order_refund_evidence e ON e.refund_id=x.id WHERE x.request_id=$1),'[]'::jsonb)
 )||CASE WHEN $2 THEN jsonb_build_object('driver_cash',jsonb_build_object(
 'paid',COALESCE((SELECT sum(amount) FROM public.direct_order_driver_cash_movements WHERE request_id=$1 AND kind='payout'),0),
 'recovered_cash',COALESCE((SELECT sum(amount) FROM public.direct_order_driver_cash_movements WHERE request_id=$1 AND kind='recovery' AND method='CASH'),0),
 'recovered_bank',COALESCE((SELECT sum(amount) FROM public.direct_order_driver_cash_movements WHERE request_id=$1 AND kind='recovery' AND method='BANKTRANSFER'),0),
 'movements',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',id,'kind',kind,'amount',amount,'method',method,'reference',reference,
 'occurred_at',occurred_at,'evidence_message_id',evidence_message_id,'parent_id',parent_id) ORDER BY occurred_at,id)
 FROM public.direct_order_driver_cash_movements WHERE request_id=$1),'[]'::jsonb))) ELSE '{}'::jsonb END
 FROM public.direct_order_requests r CROSS JOIN public.direct_order_refund_balance($1) b WHERE r.id=$1;
$$;
REVOKE ALL ON FUNCTION public.direct_order_support_context(uuid,boolean) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_public_refund_details(p_session_id uuid,p_secret_hash text,p_request_id uuid,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE s public.direct_order_sessions%ROWTYPE;r public.direct_order_requests%ROWTYPE;
BEGIN
 s:=public.direct_order_validate_session($1,$2);
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$3 AND session_id=s.id AND restaurant_id=s.restaurant_id FOR UPDATE;
 IF NOT FOUND OR r.support_closed_at IS NOT NULL OR p_payload IS NULL OR jsonb_typeof(p_payload)<>'object'
 OR EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) k WHERE k NOT IN ('bank','account','holder'))
 OR EXISTS(SELECT 1 FROM jsonb_each(p_payload) e WHERE jsonb_typeof(e.value)<>'string')
 OR char_length(btrim(COALESCE(p_payload->>'bank',''))) NOT BETWEEN 1 AND 100
 OR char_length(btrim(COALESCE(p_payload->>'account',''))) NOT BETWEEN 1 AND 100
 OR char_length(btrim(COALESCE(p_payload->>'holder',''))) NOT BETWEEN 1 AND 200
 THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_INPUT_INVALID'; END IF;
 IF r.state NOT IN ('cancelled','rejected','expired') AND public.direct_order_overpayment_due(r.id)<=0
 AND (public.direct_order_delivery_cost_balance(r.id)->>'refund_due')::numeric<=0
 AND NOT (r.fulfillment_method='pickup' AND public.direct_order_original_delivery_refund_remaining(r.id)>0)
 THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_NOT_ALLOWED'; END IF;
 UPDATE public.direct_order_requests SET refund_details=p_payload||jsonb_build_object('status','pending'),support_version=support_version+1 WHERE id=r.id;
 RETURN public.direct_order_support_context(r.id,false);
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_public_refund_details(uuid,text,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_refund_details(uuid,text,uuid,jsonb) TO service_role;
-- Keep links and evidence while customer money is still held after delivery.
ALTER FUNCTION public.direct_order_access_is_open(uuid) RENAME TO direct_order_access_before_reconciliation;
REVOKE ALL ON FUNCTION public.direct_order_access_before_reconciliation(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_access_is_open(p_request_id uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT public.direct_order_access_before_reconciliation($1) OR COALESCE((SELECT r.support_closed_at IS NULL AND r.pii_purged_at IS NULL
 AND (public.direct_order_overpayment_due(r.id)>0 OR EXISTS(SELECT 1 FROM public.direct_order_refund_records x WHERE x.request_id=r.id AND x.recorded_at>now()-interval '7 days')) FROM public.direct_order_requests r WHERE r.id=$1),false); $$;
REVOKE ALL ON FUNCTION public.direct_order_access_is_open(uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_access_is_open(uuid) TO service_role;
DO $advance_retention$
DECLARE d text;sig text;
BEGIN
 FOREACH sig IN ARRAY ARRAY['public.direct_order_cleanup_candidates(integer)','public.direct_order_cleanup_expired_pii(uuid[])'] LOOP
 SELECT pg_get_functiondef(sig::regprocedure) INTO d;
 IF strpos(d,'AND request_row.pii_purged_at IS NULL')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_CLEANUP_ANCHOR_DRIFT'; END IF;
 EXECUTE replace(d,'AND request_row.pii_purged_at IS NULL','AND request_row.pii_purged_at IS NULL AND public.direct_order_overpayment_due(request_row.id)=0');
 END LOOP;
 SELECT pg_get_functiondef('public.direct_order_cleanup_expired_pii(uuid[])'::regprocedure) INTO d;
 EXECUTE replace(d,'EXISTS(SELECT 1 FROM public.direct_order_delivery_cost_changes c WHERE c.evidence_message_id=message.id)',
 'EXISTS(SELECT 1 FROM public.direct_order_delivery_cost_changes c WHERE c.evidence_message_id=message.id) OR EXISTS(SELECT 1 FROM public.direct_order_refund_evidence e WHERE e.evidence_message_id=message.id) OR EXISTS(SELECT 1 FROM public.direct_order_driver_cash_movements e WHERE e.evidence_message_id=message.id)');
 SELECT pg_get_functiondef('public.direct_order_cleanup_expired_pii(uuid[])'::regprocedure) INTO d;
 d:=replace(d,'WHERE session_row.expires_at <',
 'WHERE NOT EXISTS(SELECT 1 FROM public.direct_order_requests retained WHERE retained.session_id=session_row.id AND (EXISTS(SELECT 1 FROM public.direct_order_payment_receipts x WHERE x.request_id=retained.id) OR EXISTS(SELECT 1 FROM public.direct_order_financials x WHERE x.request_id=retained.id) OR EXISTS(SELECT 1 FROM public.direct_order_refund_records x WHERE x.request_id=retained.id) OR EXISTS(SELECT 1 FROM public.direct_order_driver_cash_movements x WHERE x.request_id=retained.id))) AND session_row.expires_at <');
 EXECUTE d;
END; $advance_retention$;
-- Apply actual-extra receipts only to live supported orders; preserve old API IDs.
DO $extra_proof$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_commit_attachment(uuid,uuid,text,uuid,text,text,uuid)'::regprocedure) INTO d;
 d:=replace(d,$anchor$IF p_charge_id IS NULL OR r.state IN ('cancelled','rejected','expired')$anchor$, $anchor$IF (p_charge_id IS NULL AND r.state<>'approved') OR r.state IN ('cancelled','rejected','expired')$anchor$);
 d:=replace(d,$anchor$IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;$anchor$, $anchor$IF NOT FOUND AND p_charge_id IS NOT NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;$anchor$);
 EXECUTE d;
END; $extra_proof$;
CREATE FUNCTION public.direct_order_cash_day_lock() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('direct-order-cash-day:'||NEW.restaurant_id::text||':'||((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date)::text,0));
 RETURN NEW;
END; $$;
CREATE TRIGGER direct_order_cash_day_lock BEFORE INSERT ON public.direct_order_driver_cash_movements FOR EACH ROW EXECUTE FUNCTION public.direct_order_cash_day_lock();
CREATE TRIGGER direct_order_refund_day_lock BEFORE INSERT ON public.direct_order_refund_records FOR EACH ROW EXECUTE FUNCTION public.direct_order_cash_day_lock();
CREATE TRIGGER direct_order_refund_immutable BEFORE UPDATE OR DELETE ON public.direct_order_refund_records FOR EACH ROW EXECUTE FUNCTION public.direct_order_money_immutable();
-- A read-only compatibility view replaces dispatch sums, including recoveries.
CREATE VIEW public.direct_order_cash_payout_entries WITH (security_invoker=true) AS
 SELECT restaurant_id,request_id,occurred_at cash_paid_at,CASE WHEN kind='payout' THEN amount ELSE -amount END actual_grab_fee
 FROM public.direct_order_driver_cash_movements WHERE method='CASH';
REVOKE ALL ON public.direct_order_cash_payout_entries FROM PUBLIC,anon,authenticated;
GRANT SELECT ON public.direct_order_cash_payout_entries TO service_role;
DO $closing_cash_source$
DECLARE sig text;d text;
BEGIN
 FOREACH sig IN ARRAY ARRAY['public.get_daily_closing_cash_preview(uuid,date)','public.create_daily_closing(uuid,text,jsonb,numeric,date)','public.get_daily_closing_days(uuid,integer)'] LOOP
 SELECT pg_get_functiondef(sig::regprocedure) INTO d;
 IF strpos(d,'public.direct_order_dispatches')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_CLOSING_ANCHOR_DRIFT: %',sig; END IF;
 d:=replace(d,'public.direct_order_dispatches','public.direct_order_cash_payout_entries');
 IF sig LIKE 'public.create_daily_closing%' THEN
 d:=replace(d,'v_cash_variance numeric(15,2);','v_cash_variance numeric(15,2); v_cash_refunds numeric(15,2);');
 d:=replace(d,'  v_expected_cash :=',E'  SELECT COALESCE(sum(x.amount),0) INTO v_cash_refunds FROM public.direct_order_refund_records x JOIN public.direct_order_refund_evidence e ON e.refund_id=x.id WHERE x.restaurant_id=p_store_id AND e.method=\'CASH\' AND x.recorded_at>=v_day_start AND x.recorded_at<v_day_end;\n  v_expected_cash :=');
 d:=replace(d,'p_opening_cash_amount + v_payments_cash - v_delivery_cash_payout','p_opening_cash_amount + v_payments_cash - v_delivery_cash_payout - v_cash_refunds');
 END IF;
 EXECUTE d;
 END LOOP;
END; $closing_cash_source$;
ALTER TABLE public.daily_closings DROP CONSTRAINT IF EXISTS daily_closings_delivery_cash_payout_check;
ALTER TABLE public.daily_closings ADD COLUMN direct_order_cash_refunds numeric(15,2) NOT NULL DEFAULT 0;
ALTER FUNCTION public.get_daily_closing_cash_preview(uuid,date) RENAME TO get_daily_closing_cash_before_reconciliation;
REVOKE ALL ON FUNCTION public.get_daily_closing_cash_before_reconciliation(uuid,date) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.get_daily_closing_cash_preview(p_store_id uuid,p_closing_date date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE b jsonb; day date; started timestamptz; finished timestamptz; refunds numeric;paid numeric; recovered numeric;
BEGIN
 b:=public.get_daily_closing_cash_before_reconciliation($1,$2);day:=(b->>'closing_date')::date;
 started:=day::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';finished:=(day+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
 SELECT COALESCE(sum(x.amount),0) INTO refunds FROM public.direct_order_refund_records x JOIN public.direct_order_refund_evidence e ON e.refund_id=x.id
 WHERE x.restaurant_id=$1 AND e.method='CASH' AND x.recorded_at>=started AND x.recorded_at<finished;
 SELECT COALESCE(sum(amount) FILTER(WHERE kind='payout'),0),COALESCE(sum(amount) FILTER(WHERE kind='recovery' AND method='CASH'),0)
 INTO paid,recovered FROM public.direct_order_driver_cash_movements WHERE restaurant_id=$1 AND occurred_at>=started AND occurred_at<finished;
 RETURN b||jsonb_build_object('delivery_cash_paid',paid,'delivery_cash_recovered',recovered,'direct_order_cash_refunds',refunds,
 'expected_cash_amount',(b->>'expected_cash_amount')::numeric-refunds);
END; $$;
REVOKE ALL ON FUNCTION public.get_daily_closing_cash_preview(uuid,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_daily_closing_cash_preview(uuid,date) TO authenticated,service_role;
-- Persist the exact cash refund component in the same closing transaction.
ALTER FUNCTION public.create_daily_closing(uuid,text,jsonb,numeric,date) RENAME TO create_daily_closing_before_reconciliation;
REVOKE ALL ON FUNCTION public.create_daily_closing_before_reconciliation(uuid,text,jsonb,numeric,date) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.create_daily_closing(p_store_id uuid,p_notes text DEFAULT NULL,p_cash_denominations jsonb DEFAULT '{}'::jsonb,p_opening_cash_amount numeric DEFAULT 5000000,p_closing_date date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE b jsonb;day date;refunds numeric;
BEGIN
 day:=COALESCE($5,(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date);
 PERFORM pg_advisory_xact_lock(hashtextextended('direct-order-cash-day:'||$1::text||':'||day::text,0));
 b:=public.create_daily_closing_before_reconciliation($1,$2,$3,$4,$5);
 SELECT COALESCE(sum(x.amount),0) INTO refunds FROM public.direct_order_refund_records x JOIN public.direct_order_refund_evidence e ON e.refund_id=x.id
 WHERE x.restaurant_id=$1 AND e.method='CASH' AND x.recorded_at>=day::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' AND x.recorded_at<(day+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
 UPDATE public.daily_closings SET direct_order_cash_refunds=refunds WHERE restaurant_id=$1 AND closing_date=day;
 RETURN b||jsonb_build_object('direct_order_cash_refunds',refunds);
END; $$;
REVOKE ALL ON FUNCTION public.create_daily_closing(uuid,text,jsonb,numeric,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_daily_closing(uuid,text,jsonb,numeric,date) TO authenticated,service_role;
ALTER TABLE public.daily_closings ADD COLUMN delivery_cash_paid numeric(15,2) NOT NULL DEFAULT 0,
 ADD COLUMN delivery_cash_recovered numeric(15,2) NOT NULL DEFAULT 0;
UPDATE public.daily_closings SET delivery_cash_paid=greatest(delivery_cash_payout,0);
DO $closing_history$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.create_daily_closing(uuid,text,jsonb,numeric,date)'::regprocedure) INTO d;
 d:=replace(d,'SET direct_order_cash_refunds=refunds',
 'SET delivery_cash_paid=COALESCE((SELECT sum(amount) FROM public.direct_order_driver_cash_movements WHERE restaurant_id=$1 AND kind=''payout'' AND occurred_at>=day::timestamp AT TIME ZONE ''Asia/Ho_Chi_Minh'' AND occurred_at<(day+1)::timestamp AT TIME ZONE ''Asia/Ho_Chi_Minh''),0), delivery_cash_recovered=COALESCE((SELECT sum(amount) FROM public.direct_order_driver_cash_movements WHERE restaurant_id=$1 AND kind=''recovery'' AND method=''CASH'' AND occurred_at>=day::timestamp AT TIME ZONE ''Asia/Ho_Chi_Minh'' AND occurred_at<(day+1)::timestamp AT TIME ZONE ''Asia/Ho_Chi_Minh''),0),direct_order_cash_refunds=refunds');
 EXECUTE d;
 SELECT pg_get_functiondef('public.get_daily_closing_days(uuid,integer)'::regprocedure) INTO d;
 -- pg_get_functiondef normalizes RETURNS TABLE into a single line.
 d:=replace(d,'ledger_as_of timestamp with time zone)', 'ledger_as_of timestamp with time zone, direct_order_cash_refunds numeric, delivery_cash_paid numeric, delivery_cash_recovered numeric)');
 IF strpos(d,'direct_order_cash_refunds numeric')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_CLOSING_HISTORY_DRIFT'; END IF;
 d:=replace(d,E'    now()\n  FROM business_days',$history$    now(), CASE WHEN closing.close_source='manual' THEN closing.direct_order_cash_refunds ELSE COALESCE(refunds.amount,0) END, CASE WHEN closing.close_source='manual' THEN closing.delivery_cash_paid ELSE COALESCE(cash.paid,0) END, CASE WHEN closing.close_source='manual' THEN closing.delivery_cash_recovered ELSE COALESCE(cash.recovered,0) END
  FROM business_days$history$);
 d:=replace(d,'  ORDER BY day_row.business_date DESC;',
 $join$  LEFT JOIN (SELECT (x.recorded_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS business_date,sum(x.amount) amount FROM public.direct_order_refund_records x JOIN public.direct_order_refund_evidence e ON e.refund_id=x.id WHERE x.restaurant_id=p_store_id AND e.method='CASH' AND x.recorded_at>=((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date-v_limit+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' GROUP BY 1) refunds ON refunds.business_date=day_row.business_date
  LEFT JOIN (SELECT (occurred_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS business_date,sum(amount) FILTER(WHERE kind='payout') paid,sum(amount) FILTER(WHERE kind='recovery' AND method='CASH') recovered FROM public.direct_order_driver_cash_movements WHERE restaurant_id=p_store_id AND occurred_at>=((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date-v_limit+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' GROUP BY 1) cash ON cash.business_date=day_row.business_date
  ORDER BY day_row.business_date DESC;$join$);
 DROP FUNCTION public.get_daily_closing_days(uuid,integer);
 EXECUTE d;
END; $closing_history$;
REVOKE ALL ON FUNCTION public.get_daily_closing_days(uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_daily_closing_days(uuid,integer) TO authenticated,service_role;
-- Retain outstanding excess refunds before the predecessor filters and limits.
DO $cashier_refund_page$
DECLARE d text;original text;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_staff_list_v3(uuid,text[],integer,text)'::regprocedure) INTO d;
 original:=d;
 d:=replace(d,'WITH page AS MATERIALIZED (',$cte$WITH receipt_excess AS MATERIALIZED (
 SELECT x.request_id,sum(x.actual_amount-x.amount) amount FROM public.direct_order_payment_receipts x
 JOIN public.direct_order_requests r ON r.id=x.request_id WHERE r.restaurant_id=p_store_id GROUP BY x.request_id HAVING sum(x.actual_amount-x.amount)>0
 ), refunded_excess AS MATERIALIZED (
 SELECT request_id,sum(overpayment_amount) amount FROM public.direct_order_refund_records WHERE restaurant_id=p_store_id GROUP BY request_id
 ), page AS MATERIALIZED ($cte$);
 IF d=original THEN RAISE EXCEPTION 'DIRECT_ORDER_CLOSING_ANCHOR_DRIFT'; END IF;
 original:=d;
 d:=replace(d,'LEFT JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id=r.id',
 'LEFT JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id=r.id LEFT JOIN receipt_excess rc ON rc.request_id=r.id LEFT JOIN refunded_excess rf ON rf.request_id=r.id');
 IF d=original THEN RAISE EXCEPTION 'DIRECT_ORDER_CLOSING_ANCHOR_DRIFT'; END IF;
 original:=d;
 d:=replace(d,$before$OR r.state='approved' AND (t.id IS NULL OR t.status NOT IN ('completed','cancelled'))$before$,
 $after$OR r.state='approved' AND (t.id IS NULL OR t.status NOT IN ('completed','cancelled')) OR COALESCE(rc.amount,0)>COALESCE(rf.amount,0)$after$);
 IF d=original THEN RAISE EXCEPTION 'DIRECT_ORDER_CLOSING_ANCHOR_DRIFT'; END IF;
 EXECUTE d;
END; $cashier_refund_page$;
-- Cashier pages calculate payment exceptions in one batch over their page.
ALTER FUNCTION public.direct_order_staff_list_v3(uuid,text[],integer,text) RENAME TO direct_order_staff_list_before_reconciliation;
REVOKE ALL ON FUNCTION public.direct_order_staff_list_before_reconciliation(uuid,text[],integer,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_staff_list_v3(p_store_id uuid,p_states text[] DEFAULT NULL,p_limit integer DEFAULT 100,p_fulfillment_type text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH page AS(SELECT e.value,e.ordinality FROM jsonb_array_elements(public.direct_order_staff_list_before_reconciliation($1,$2,$3,$4)) WITH ORDINALITY e),
 receipts AS(SELECT x.request_id,sum(x.actual_amount-x.amount) excess,sum(x.amount) FILTER(WHERE c.kind IS DISTINCT FROM 'delivery') food FROM public.direct_order_payment_receipts x LEFT JOIN public.direct_order_payment_charges c ON c.id=x.charge_id WHERE x.request_id IN(SELECT(value->>'id')::uuid FROM page) GROUP BY x.request_id),
 refunds AS(SELECT request_id,sum(overpayment_amount) excess FROM public.direct_order_refund_records WHERE request_id IN(SELECT(value->>'id')::uuid FROM page) GROUP BY request_id)
 SELECT COALESCE(jsonb_agg(p.value||jsonb_build_object('overpayment_due',greatest(0,COALESCE(x.excess,0)-COALESCE(f.excess,0)),
 'food_due',CASE WHEN p.value->>'state' IN ('awaiting_payment_review','quoted') THEN greatest(0,COALESCE((p.value->>'final_total')::numeric,0)-COALESCE(x.food,0)) ELSE 0 END,
 'refund_pending',COALESCE((p.value->>'refund_pending')::boolean,false) OR COALESCE(x.excess,0)>COALESCE(f.excess,0)) ORDER BY p.ordinality),'[]'::jsonb)
 FROM page p LEFT JOIN receipts x ON x.request_id::text=p.value->>'id' LEFT JOIN refunds f ON f.request_id=x.request_id;
$$;
REVOKE ALL ON FUNCTION public.direct_order_staff_list_v3(uuid,text[],integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_list_v3(uuid,text[],integer,text) TO authenticated,service_role;
-- The customer and staff language selections remain independent. New orders
-- default to store prepayment without rewriting finalized/historical quotes.
ALTER FUNCTION public.direct_order_staff_quote_with_payment_mode(uuid,uuid,numeric,text,text) RENAME TO direct_order_quote_before_cash_default;
REVOKE ALL ON FUNCTION public.direct_order_quote_before_cash_default(uuid,uuid,numeric,text,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_staff_quote_with_payment_mode(p_store_id uuid,p_request_id uuid,p_delivery_fee_total numeric,p_cashier_note text DEFAULT NULL,p_delivery_payment_mode text DEFAULT 'store_prepaid')
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_catalog AS $$ SELECT public.direct_order_quote_before_cash_default($1,$2,$3,$4,$5); $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_quote_with_payment_mode(uuid,uuid,numeric,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_quote_with_payment_mode(uuid,uuid,numeric,text,text) TO authenticated,service_role;
DO $verify$
BEGIN
 IF has_table_privilege('authenticated','public.direct_order_driver_cash_movements','SELECT')
 OR has_function_privilege('authenticated','public.direct_order_support_context(uuid,boolean)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_staff_support_before_reconciliation(uuid,uuid,integer,text,jsonb)','EXECUTE')
 THEN RAISE EXCEPTION 'DIRECT_ORDER_RECONCILIATION_PERMISSIONS'; END IF;
END; $verify$;
COMMIT;
