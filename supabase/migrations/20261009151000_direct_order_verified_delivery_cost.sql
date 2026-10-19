-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
CREATE TABLE public.direct_order_delivery_cost_changes(
 id uuid PRIMARY KEY,request_id uuid NOT NULL REFERENCES public.direct_order_requests(id),restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 sequence bigint GENERATED ALWAYS AS IDENTITY,previous_fee numeric(15,2) NOT NULL CHECK(previous_fee>=0),actual_fee numeric(15,2) NOT NULL CHECK(actual_fee>=0 AND actual_fee=trunc(actual_fee)),
 provider text NOT NULL CHECK(provider IN ('grab','be','other')),reference text NOT NULL CHECK(char_length(reference) BETWEEN 1 AND 200),
 evidence_message_id uuid NOT NULL REFERENCES public.direct_order_messages(id),recorded_by uuid NOT NULL REFERENCES auth.users(id),created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX direct_order_delivery_cost_request ON public.direct_order_delivery_cost_changes(request_id,sequence DESC);
ALTER TABLE public.direct_order_delivery_cost_changes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.direct_order_delivery_cost_changes FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.direct_order_delivery_cost_changes TO service_role;
CREATE FUNCTION public.direct_order_delivery_cost_immutable() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'DIRECT_ORDER_DELIVERY_COST_IMMUTABLE'; END; $$;
CREATE TRIGGER direct_order_delivery_cost_immutable BEFORE UPDATE OR DELETE ON public.direct_order_delivery_cost_changes FOR EACH ROW EXECUTE FUNCTION public.direct_order_delivery_cost_immutable();
ALTER TABLE public.direct_order_refund_records DROP CONSTRAINT direct_order_refund_records_purpose_check;
ALTER TABLE public.direct_order_refund_records ADD CONSTRAINT direct_order_refund_records_purpose_check CHECK(purpose IN ('cancellation','pickup_delivery','delivery_adjustment'));
ALTER TABLE public.direct_order_refund_records ADD COLUMN delivery_adjustment_ids uuid[] NOT NULL DEFAULT '{}'::uuid[];
ALTER TABLE public.direct_order_payment_charges ADD COLUMN credited_receipt_ids uuid[] NOT NULL DEFAULT '{}'::uuid[];
CREATE FUNCTION public.direct_order_delivery_cost_balance(p_request_id uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH latest AS (SELECT actual_fee FROM public.direct_order_delivery_cost_changes WHERE request_id=$1 ORDER BY sequence DESC LIMIT 1),
 collected AS (SELECT COALESCE((SELECT delivery_fee_total FROM public.direct_order_financials WHERE request_id=$1 AND delivery_payment_mode='store_prepaid'),0)+COALESCE((SELECT sum(r.amount) FROM public.direct_order_payment_receipts r JOIN public.direct_order_payment_charges c ON c.id=r.charge_id WHERE r.request_id=$1 AND c.kind='delivery'),0)-COALESCE((SELECT sum(amount) FROM public.direct_order_refund_records WHERE request_id=$1 AND purpose='delivery_adjustment'),0) amount)
 SELECT jsonb_build_object('actual_fee',l.actual_fee,'collected',c.amount,'refund_due',CASE WHEN EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=$1 AND delivery_payment_mode='store_prepaid') AND EXISTS(SELECT 1 FROM public.direct_order_requests WHERE id=$1 AND state='approved' AND fulfillment_method='delivery') THEN greatest(0,c.amount-COALESCE(l.actual_fee,c.amount)) ELSE 0 END)
 FROM collected c LEFT JOIN latest l ON true;
$$;
CREATE FUNCTION public.direct_order_original_delivery_refund_remaining(p_request_id uuid) RETURNS numeric
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT greatest(0,f.delivery_fee_total-COALESCE((SELECT sum(a.amount) FROM public.payment_adjustments a WHERE a.payment_id=f.payment_id AND a.id IN (SELECT unnest(x.delivery_adjustment_ids) FROM public.direct_order_refund_records x WHERE x.request_id=$1 AND x.purpose='delivery_adjustment')),0))
 FROM public.direct_order_financials f WHERE f.request_id=$1;
$$;
REVOKE ALL ON FUNCTION public.direct_order_original_delivery_refund_remaining(uuid) FROM PUBLIC,anon,authenticated;
-- Book confirmed advances when a verified cost supersedes a partly paid demand.
-- Receipt and proof IDs stay unchanged; the financial charge references them.
CREATE FUNCTION public.direct_order_post_delivery_advance(p_request_id uuid,p_store_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE amount numeric; rate numeric; pretax numeric; o public.orders%ROWTYPE; payment public.payments%ROWTYPE; refs uuid[];
BEGIN
 SELECT greatest(0,COALESCE((SELECT sum(x.amount) FROM public.direct_order_payment_receipts x JOIN public.direct_order_payment_charges c ON c.id=x.charge_id WHERE x.request_id=$1 AND c.kind='delivery'),0)
  -COALESCE((SELECT sum(c.amount) FROM public.direct_order_payment_charges c WHERE c.request_id=$1 AND c.kind='delivery' AND c.payment_id IS NOT NULL),0)
  -COALESCE((SELECT sum(unposted_amount) FROM public.direct_order_refund_records WHERE request_id=$1),0)) INTO amount;
 IF amount<=0 THEN RETURN; END IF;
 SELECT array_agg(x.id ORDER BY x.confirmed_at,x.id) INTO refs FROM public.direct_order_payment_receipts x JOIN public.direct_order_payment_charges c ON c.id=x.charge_id
 WHERE x.request_id=$1 AND c.kind='delivery' AND c.payment_id IS NULL AND NOT EXISTS(SELECT 1 FROM public.direct_order_payment_charges credited WHERE credited.request_id=$1 AND x.id=ANY(credited.credited_receipt_ids));
 SELECT delivery_fee_vat_rate INTO rate FROM public.direct_order_storefronts WHERE restaurant_id=$2;
 pretax:=round(amount/(1+rate/100),2);
 INSERT INTO public.orders(restaurant_id,table_id,sales_channel,status,guest_count,created_by,notes,order_source,order_purpose,fulfillment_mode_snapshot)
 VALUES($2,NULL,'delivery','serving',NULL,auth.uid(),'Verified delivery advance','staff','customer','pos_print') RETURNING * INTO o;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,item_type,label,display_name,unit_price,quantity,status,vat_rate,vat_amount,total_amount_ex_tax,paying_amount_inc_tax,is_service_item,fulfillment_mode_snapshot)
 VALUES($2,o.id,NULL,'service_charge','Phí giao hàng','Phí giao hàng',pretax,1,'served',rate,amount-pretax,pretax,amount,false,'pos_print');
 payment:=public.process_payment(o.id,$2,amount,'BANKTRANSFER');
 IF payment.amount_portion IS DISTINCT FROM amount THEN RAISE EXCEPTION 'DIRECT_ORDER_FINANCIAL_RECONCILIATION_FAILED'; END IF;
 INSERT INTO public.direct_order_payment_charges(request_id,restaurant_id,kind,amount,reason,status,created_by,order_id,payment_id,credited_receipt_ids)
 VALUES($1,$2,'delivery',amount,'Confirmed advance applied to verified delivery cost','paid',auth.uid(),o.id,payment.id,COALESCE(refs,'{}'::uuid[]));
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'direct_order_delivery_advance_posted','direct_order_requests',$1,jsonb_build_object('payment_id',payment.id,'amount',amount,'receipt_ids',refs));
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_post_delivery_advance(uuid,uuid) FROM PUBLIC,anon,authenticated;
ALTER FUNCTION public.direct_order_support_context(uuid,boolean) RENAME TO direct_order_support_context_before_cost;
REVOKE ALL ON FUNCTION public.direct_order_support_context_before_cost(uuid,boolean) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_support_context(p_request_id uuid,p_staff boolean DEFAULT false) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT public.direct_order_support_context_before_cost($1,$2)||jsonb_build_object('delivery_cost',public.direct_order_delivery_cost_balance($1),'delivery_adjustment_refund_due',(public.direct_order_delivery_cost_balance($1)->>'refund_due')::numeric,
 'delivery_cost_changes',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',id,'previous_fee',previous_fee,'actual_fee',actual_fee,'provider',provider,'reference',reference,'evidence_message_id',evidence_message_id) ORDER BY created_at,id) FROM public.direct_order_delivery_cost_changes WHERE request_id=$1),'[]'::jsonb));
$$;
REVOKE ALL ON FUNCTION public.direct_order_support_context(uuid,boolean),public.direct_order_delivery_cost_balance(uuid) FROM PUBLIC,anon,authenticated;
ALTER FUNCTION public.direct_order_staff_support_action(uuid,uuid,integer,text,jsonb) RENAME TO direct_order_staff_support_before_cost;
REVOKE ALL ON FUNCTION public.direct_order_staff_support_before_cost(uuid,uuid,integer,text,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_staff_support_action(p_store_id uuid,p_request_id uuid,p_expected_version integer,p_action text,p_payload jsonb) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE r public.direct_order_requests%ROWTYPE; f public.direct_order_financials%ROWTYPE; old public.direct_order_delivery_cost_changes%ROWTYPE;
 refund public.direct_order_refund_records%ROWTYPE; operation uuid; amount numeric; previous numeric; balance jsonb; delta numeric; left_amount numeric; part numeric; c record; adjustment uuid; adjustments uuid[]:='{}'::uuid[];
BEGIN
 PERFORM public.direct_order_require_actor(p_store_id,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 IF p_action='charge' AND p_payload->>'kind'='delivery' OR p_action='no_delivery_fee' THEN RAISE EXCEPTION 'DIRECT_ORDER_DELIVERY_EVIDENCE_REQUIRED'; END IF;
 IF p_action NOT IN ('reconcile_delivery_fee','refund_delivery_adjustment') THEN RETURN public.direct_order_staff_support_before_cost($1,$2,$3,$4,$5); END IF;
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 operation:=(p_payload->>'operation_id')::uuid; amount:=(p_payload->>'amount')::numeric;
 IF operation IS NULL OR amount IS NULL OR amount<0 OR amount<>trunc(amount) OR amount::text IN ('NaN','Infinity','-Infinity') OR char_length(btrim(COALESCE(p_payload->>'reference',''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_INVALID'; END IF;
 IF p_action='reconcile_delivery_fee' THEN
  SELECT * INTO old FROM public.direct_order_delivery_cost_changes WHERE id=operation;
  IF FOUND THEN
   IF old.request_id<>r.id OR old.actual_fee<>amount OR old.provider IS DISTINCT FROM p_payload->>'provider' OR old.reference IS DISTINCT FROM btrim(p_payload->>'reference') OR old.evidence_message_id IS DISTINCT FROM (p_payload->>'evidence_message_id')::uuid THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_CHANGED'; END IF;
   RETURN public.direct_order_support_context(r.id,true);
  END IF;
 ELSE
  SELECT * INTO refund FROM public.direct_order_refund_records WHERE id=operation;
  IF FOUND THEN
   IF refund.request_id<>r.id OR refund.purpose<>'delivery_adjustment' OR refund.amount<>amount OR refund.reference IS DISTINCT FROM btrim(p_payload->>'reference') THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_CHANGED'; END IF;
   RETURN public.direct_order_support_context(r.id,true);
  END IF;
 END IF;
 IF r.support_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_CHANGED'; END IF;
 SELECT * INTO f FROM public.direct_order_financials WHERE request_id=r.id;
 IF r.state<>'approved' OR f.request_id IS NULL OR r.fulfillment_method<>'delivery' OR EXISTS(SELECT 1 FROM public.direct_delivery_fulfillment_tickets WHERE request_id=r.id AND status IN ('dispatched','completed','cancelled')) THEN RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;
 balance:=public.direct_order_delivery_cost_balance(r.id);
 IF p_action='reconcile_delivery_fee' THEN
  IF p_payload->>'provider' IS NULL OR p_payload->>'provider' NOT IN ('grab','be','other') OR NOT EXISTS(SELECT 1 FROM public.direct_order_messages WHERE id=(p_payload->>'evidence_message_id')::uuid AND request_id=r.id AND restaurant_id=p_store_id AND sender_type='cashier' AND message_type='attachment' AND attachment_storage_path IS NOT NULL) THEN RAISE EXCEPTION 'DIRECT_ORDER_DELIVERY_EVIDENCE_REQUIRED'; END IF;
  previous:=COALESCE((balance->>'actual_fee')::numeric,f.delivery_fee_total);
  INSERT INTO public.direct_order_delivery_cost_changes(id,request_id,restaurant_id,previous_fee,actual_fee,provider,reference,evidence_message_id,recorded_by) VALUES(operation,r.id,p_store_id,previous,amount,p_payload->>'provider',btrim(p_payload->>'reference'),(p_payload->>'evidence_message_id')::uuid,auth.uid());
  -- Old unpaid demands are superseded; confirmed receipts always remain in the ledger.
  UPDATE public.direct_order_payment_charges SET status='void' WHERE request_id=r.id AND kind='delivery' AND status NOT IN ('paid','void');
  PERFORM public.direct_order_post_delivery_advance(r.id,p_store_id);
  delta:=amount-(balance->>'collected')::numeric;
  IF f.delivery_payment_mode='store_prepaid' AND delta>0 THEN
   INSERT INTO public.direct_order_payment_charges(request_id,restaurant_id,kind,amount,reason,status,created_by) VALUES(r.id,p_store_id,'delivery',delta,'Actual delivery fee: '||(p_payload->>'provider')||' / '||btrim(p_payload->>'reference'),'pending',auth.uid());
  END IF;
  UPDATE public.direct_order_requests SET delivery_fee_finalized=true WHERE id=r.id;
  INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,metadata) VALUES(r.id,p_store_id,'system','system','Delivery fee updated from verified provider cost',jsonb_build_object('event','verified_delivery_cost','previous_fee',previous,'actual_fee',amount,'difference',CASE WHEN f.delivery_payment_mode='store_prepaid' THEN delta ELSE 0 END,'provider',p_payload->>'provider','reference',p_payload->>'reference'));
 ELSE
  IF amount<=0 OR amount>(balance->>'refund_due')::numeric THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_AMOUNT_INVALID'; END IF;
  left_amount:=amount;
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
  INSERT INTO public.direct_order_refund_records(id,request_id,restaurant_id,amount,unposted_amount,purpose,reference,recorded_by,delivery_adjustment_ids) VALUES(operation,r.id,p_store_id,amount,left_amount,'delivery_adjustment',btrim(p_payload->>'reference'),auth.uid(),adjustments);
 END IF;
 UPDATE public.direct_order_requests SET support_version=support_version+1 WHERE id=r.id;
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'direct_order_'||p_action,'direct_order_requests',r.id,jsonb_build_object('operation_id',operation,'amount',amount,'previous_fee',previous));
 RETURN public.direct_order_support_context(r.id,true);
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_staff_support_action(uuid,uuid,integer,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_support_action(uuid,uuid,integer,text,jsonb) TO authenticated,service_role;
DO $settlement$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_assert_settled(uuid)'::regprocedure) INTO d;
 IF strpos(d,'IF EXISTS(')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_COST_SETTLEMENT_DRIFT'; END IF;
 EXECUTE replace(d,'IF EXISTS(','IF (public.direct_order_delivery_cost_balance(p_request_id)->>''refund_due'')::numeric>0 OR EXISTS(');
END;
$settlement$;
CREATE FUNCTION public.direct_order_verify_dispatch_cost() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE actual numeric; balance jsonb;
BEGIN
 IF NEW.delivery_payment_mode='customer_direct' THEN RETURN NEW; END IF;
 SELECT actual_fee INTO actual FROM public.direct_order_delivery_cost_changes WHERE request_id=NEW.request_id ORDER BY sequence DESC LIMIT 1;
 IF FOUND AND NEW.actual_grab_fee IS DISTINCT FROM actual THEN RAISE EXCEPTION 'DIRECT_ORDER_DELIVERY_COST_CHANGED'; END IF;
 IF NOT FOUND AND NEW.actual_grab_fee IS DISTINCT FROM NEW.customer_delivery_fee AND EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=NEW.request_id AND delivery_payment_mode='store_prepaid') THEN RAISE EXCEPTION 'DIRECT_ORDER_DELIVERY_EVIDENCE_REQUIRED'; END IF;
 IF actual IS NOT NULL THEN
  balance:=public.direct_order_delivery_cost_balance(NEW.request_id);
  NEW.customer_delivery_fee:=(balance->>'collected')::numeric;
  NEW.fee_variance:=NEW.customer_delivery_fee-actual;
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER zz_direct_order_verify_dispatch_cost BEFORE INSERT ON public.direct_order_dispatches FOR EACH ROW EXECUTE FUNCTION public.direct_order_verify_dispatch_cost();
-- Pickup refunds only the original shipping portion still held by the store.
-- Verified shipping refunds carry exact adjustment IDs, so unknown manual
-- adjustments continue to require the existing reconciliation procedure.
DO $pickup_refund_compatibility$
DECLARE d text; signature text;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_staff_record_pickup_refund(uuid,uuid,uuid,text)'::regprocedure) INTO d;
 IF strpos(d,'v_fin.delivery_fee_total<=0')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_COST_SETTLEMENT_DRIFT'; END IF;
 d:=replace(d,'v_adjustment public.payment_adjustments%ROWTYPE;','v_adjustment public.payment_adjustments%ROWTYPE; v_remaining numeric;');
 d:=replace(d,'IF NOT FOUND OR v_fin.delivery_fee_total<=0 THEN RAISE EXCEPTION ''DIRECT_ORDER_REFUND_NOT_DUE''; END IF;',
  'IF NOT FOUND THEN RAISE EXCEPTION ''DIRECT_ORDER_REFUND_NOT_DUE''; END IF; v_remaining:=public.direct_order_original_delivery_refund_remaining(p_request_id); IF v_remaining<=0 THEN RETURN public.direct_order_fulfillment_context(p_request_id); END IF;');
 d:=replace(d,'EXISTS(SELECT 1 FROM public.payment_adjustments WHERE payment_id=v_fin.payment_id)',
  'EXISTS(SELECT 1 FROM public.payment_adjustments WHERE payment_id=v_fin.payment_id AND id NOT IN (SELECT unnest(delivery_adjustment_ids) FROM public.direct_order_refund_records WHERE request_id=p_request_id AND purpose=''delivery_adjustment''))');
 d:=replace(d,'''refund'',v_fin.delivery_fee_total,','''refund'',v_remaining,');
 d:=replace(d,'''amount'',v_fin.delivery_fee_total,','''amount'',v_remaining,');
 EXECUTE d;
 SELECT pg_get_functiondef('public.direct_order_fulfillment_context(uuid)'::regprocedure) INTO d;
 IF strpos(d,'COALESCE(f.delivery_fee_total, q.delivery_fee_total, 0)')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_COST_SETTLEMENT_DRIFT'; END IF;
 d:=replace(d,'COALESCE(f.delivery_fee_total, q.delivery_fee_total, 0)','COALESCE(public.direct_order_original_delivery_refund_remaining(r.id), q.delivery_fee_total, 0)');
 d:=replace(d,'o.adjustment_id IS NOT NULL','(o.adjustment_id IS NOT NULL OR f.request_id IS NOT NULL AND public.direct_order_original_delivery_refund_remaining(r.id)<=0)');
 EXECUTE d;
 SELECT pg_get_functiondef('public.direct_order_access_is_open(uuid)'::regprocedure) INTO d;
 IF strpos(d,'f.delivery_fee_total>0')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_COST_SETTLEMENT_DRIFT'; END IF;
 EXECUTE replace(d,'f.delivery_fee_total>0','public.direct_order_original_delivery_refund_remaining(r.id)>0');
 FOREACH signature IN ARRAY ARRAY['public.direct_order_cleanup_candidates(integer)','public.direct_order_cleanup_expired_pii(uuid[])'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO d;
  -- Later support migrations already replace this legacy financial guard.
  -- The access lifecycle guard installed above still protects pending refunds.
  IF strpos(d,'pf.delivery_fee_total>0')=0 THEN CONTINUE; END IF;
  EXECUTE replace(d,'pf.delivery_fee_total>0','public.direct_order_original_delivery_refund_remaining(po.request_id)>0');
 END LOOP;
END; $pickup_refund_compatibility$;
-- Existing unverified fee demands require a cashier reconciliation, never customer consent.
CREATE OR REPLACE FUNCTION public.direct_order_public_charge_consent(p_session_id uuid,p_secret_hash text,p_request_id uuid,p_charge_id uuid,p_accept boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 PERFORM public.direct_order_validate_session($1,$2);
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_requests WHERE id=$3 AND session_id=$1) THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 RAISE EXCEPTION 'DIRECT_ORDER_DELIVERY_EVIDENCE_REQUIRED';
END;
$$;
DO $cost_retention$
DECLARE d text; needle text:='EXISTS(SELECT 1 FROM public.direct_order_payment_receipts r WHERE r.proof_message_id=message.id)';
BEGIN
 SELECT pg_get_functiondef('public.direct_order_cleanup_expired_pii(uuid[])'::regprocedure) INTO d;
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_COST_RETENTION_DRIFT'; END IF;
 EXECUTE replace(d,needle,'(EXISTS(SELECT 1 FROM public.direct_order_payment_receipts r WHERE r.proof_message_id=message.id) OR EXISTS(SELECT 1 FROM public.direct_order_delivery_cost_changes c WHERE c.evidence_message_id=message.id))');
END; $cost_retention$;
DO $verify$ BEGIN
 IF has_function_privilege('authenticated','public.direct_order_staff_support_before_cost(uuid,uuid,integer,text,jsonb)','EXECUTE')
  OR has_function_privilege('authenticated','public.direct_order_original_delivery_refund_remaining(uuid)','EXECUTE')
  OR has_function_privilege('authenticated','public.direct_order_post_delivery_advance(uuid,uuid)','EXECUTE')
  OR has_function_privilege('anon','public.direct_order_post_delivery_advance(uuid,uuid)','EXECUTE')
  OR has_table_privilege('authenticated','public.direct_order_delivery_cost_changes','INSERT') THEN RAISE EXCEPTION 'DIRECT_ORDER_COST_PERMISSION_DRIFT'; END IF;
END; $verify$;
COMMIT;
