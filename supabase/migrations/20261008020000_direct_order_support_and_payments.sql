-- Direct Order support, append-only verified receipts and supplemental delivery.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
DO $$ BEGIN
 PERFORM set_config('direct_order_support.payment_anchor',md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure)),true);
END $$;
-- Preserve the exact operational predecessor for a guarded metadata rollback.
CREATE TABLE public.direct_order_support_20261008020000_backup(
 object_identity text PRIMARY KEY, definition text NOT NULL, captured_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.direct_order_support_20261008020000_backup ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.direct_order_support_20261008020000_backup FROM PUBLIC,anon,authenticated,service_role;
INSERT INTO public.direct_order_support_20261008020000_backup(object_identity,definition)
SELECT signature,pg_get_functiondef(signature::regprocedure) FROM unnest(ARRAY[
 'public.direct_order_public_message(uuid,text,uuid,text)',
 'public.direct_order_staff_message(uuid,uuid,text)',
 'public.direct_order_public_submit(uuid,text,uuid,jsonb)',
 'public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)',
 'public.direct_order_fulfillment_context(uuid)',
 'public.claim_direct_order_push_deliveries(integer)',
 'public.direct_order_enqueue_customer_event(uuid,text)',
 'public.direct_order_staff_quote_with_payment_mode(uuid,uuid,numeric,text,text)',
 'public.enqueue_direct_order_customer_receipt_after_payment()',
 'public.direct_order_staff_list_v3(uuid,text[],integer,text)',
 'public.direct_order_cleanup_expired_pii(uuid[])',
 'public.direct_order_cleanup_candidates(integer)',
 'public.direct_order_analytics(uuid,date,date)'
]) signature;
ALTER TABLE public.direct_order_requests
 ADD COLUMN invoice_details jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(invoice_details)='object'),
 ADD COLUMN support_closed_at timestamptz,
 ADD COLUMN support_version integer NOT NULL DEFAULT 1,
 ADD COLUMN delivery_fee_deferred boolean NOT NULL DEFAULT false,
 ADD COLUMN delivery_fee_finalized boolean NOT NULL DEFAULT true,
 ADD COLUMN refund_details jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(refund_details)='object');
CREATE TABLE public.direct_order_payment_charges(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 request_id uuid NOT NULL REFERENCES public.direct_order_requests(id) ON DELETE RESTRICT,
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE RESTRICT,
 kind text NOT NULL CHECK(kind IN ('food_balance','delivery')),
 amount numeric(15,2) NOT NULL CHECK(amount>0 AND amount=trunc(amount)),
 reason text NOT NULL CHECK(char_length(reason) BETWEEN 1 AND 500),
 status text NOT NULL CHECK(status IN ('awaiting_consent','pending','review','paid','void')),
 created_by uuid NOT NULL REFERENCES auth.users(id),
 created_at timestamptz NOT NULL DEFAULT now(), consented_at timestamptz,
 order_id uuid UNIQUE REFERENCES public.orders(id), payment_id uuid UNIQUE REFERENCES public.payments(id),
 UNIQUE(request_id,id)
);
CREATE UNIQUE INDEX direct_order_one_open_charge ON public.direct_order_payment_charges(request_id,kind)
 WHERE status NOT IN ('paid','void');
CREATE INDEX direct_order_charges_request ON public.direct_order_payment_charges(request_id,created_at);
CREATE TABLE public.direct_order_payment_receipts(
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), request_id uuid NOT NULL REFERENCES public.direct_order_requests(id),
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 charge_id uuid REFERENCES public.direct_order_payment_charges(id),
 quote_id uuid NOT NULL REFERENCES public.direct_order_quotes(id),
 proof_message_id uuid NOT NULL UNIQUE REFERENCES public.direct_order_messages(id),
 amount numeric(15,2) NOT NULL CHECK(amount>0 AND amount=trunc(amount)),
 bank_reference text NOT NULL CHECK(char_length(bank_reference) BETWEEN 1 AND 200),
 confirmed_by uuid NOT NULL REFERENCES auth.users(id), confirmed_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX direct_order_receipts_bank_reference ON public.direct_order_payment_receipts(request_id,bank_reference);
CREATE INDEX direct_order_receipts_request ON public.direct_order_payment_receipts(request_id,confirmed_at);
CREATE TABLE public.direct_order_refund_records(
 id uuid PRIMARY KEY, request_id uuid NOT NULL REFERENCES public.direct_order_requests(id),
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 amount numeric(15,2) NOT NULL CHECK(amount>0 AND amount=trunc(amount)),
 unposted_amount numeric(15,2) NOT NULL DEFAULT 0 CHECK(unposted_amount>=0 AND unposted_amount<=amount),
 purpose text NOT NULL DEFAULT 'cancellation' CHECK(purpose IN ('cancellation','pickup_delivery')),
 reference text NOT NULL CHECK(char_length(reference) BETWEEN 1 AND 200),
 recorded_by uuid NOT NULL REFERENCES auth.users(id), recorded_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.direct_order_payment_charges ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_order_payment_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_order_refund_records ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.direct_order_payment_charges,public.direct_order_payment_receipts,public.direct_order_refund_records FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.direct_order_payment_charges,public.direct_order_payment_receipts,public.direct_order_refund_records TO service_role;
ALTER TABLE public.direct_order_messages DROP CONSTRAINT direct_order_messages_message_type_check;
ALTER TABLE public.direct_order_messages ADD CONSTRAINT direct_order_messages_message_type_check
 CHECK(message_type IN ('text','payment_proof','quote','grab_link','system','attachment'));
ALTER TABLE public.direct_order_messages DROP CONSTRAINT direct_order_messages_attachment_valid;
ALTER TABLE public.direct_order_messages ADD CONSTRAINT direct_order_messages_attachment_valid CHECK(
 attachment_storage_path IS NULL OR attachment_storage_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/[0-9a-f-]{36}[.](jpg|jpeg|png|webp|pdf)$');
ALTER TABLE public.direct_order_messages ADD CONSTRAINT direct_order_message_proof_image CHECK(
 message_type<>'payment_proof' OR attachment_storage_path ~ '[.](jpg|jpeg|png|webp)$');
INSERT INTO storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 VALUES('direct-order-chat','direct-order-chat',false,5242880,ARRAY['image/jpeg','image/png','image/webp','application/pdf'])
 ON CONFLICT(id) DO UPDATE SET public=false,file_size_limit=5242880,allowed_mime_types=EXCLUDED.allowed_mime_types;
-- All writes and URL issuance pass through the Edge function and scoped RPCs.
CREATE OR REPLACE FUNCTION public.direct_order_public_message(
  p_session_id uuid,
  p_secret_hash text,
  p_request_id uuid,
  p_body text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_session public.direct_order_sessions%ROWTYPE;
  v_request public.direct_order_requests%ROWTYPE;
  v_message public.direct_order_messages%ROWTYPE;
BEGIN
  v_session := public.direct_order_validate_session(
    p_session_id, p_secret_hash
  );
  SELECT * INTO v_request
  FROM public.direct_order_requests request_row
  WHERE request_row.id = p_request_id
    AND request_row.session_id = v_session.id
    AND request_row.restaurant_id = v_session.restaurant_id;
  IF NOT FOUND OR v_request.support_closed_at IS NOT NULL THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_CHATABLE';
  END IF;
  IF length(btrim(COALESCE(p_body, ''))) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_MESSAGE_INVALID';
  END IF;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type, body
  ) VALUES (
    v_request.id, v_request.restaurant_id, 'customer', 'text', btrim(p_body)
  ) RETURNING * INTO v_message;

  RETURN jsonb_build_object('message_id', v_message.id, 'created_at', v_message.created_at);
END;
$$;
CREATE OR REPLACE FUNCTION public.direct_order_staff_message(
  p_store_id uuid,
  p_request_id uuid,
  p_body text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_message public.direct_order_messages%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(
    p_store_id,
    ARRAY['cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin']
  );
  IF length(btrim(COALESCE(p_body, ''))) NOT BETWEEN 1 AND 2000 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_MESSAGE_INVALID';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.direct_order_requests request_row
    WHERE request_row.id = p_request_id
      AND request_row.restaurant_id = p_store_id
      AND request_row.support_closed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_CHATABLE';
  END IF;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, sender_auth_id,
    message_type, body
  ) VALUES (
    p_request_id, p_store_id, 'cashier', (SELECT auth.uid()),
    'text', btrim(p_body)
  ) RETURNING * INTO v_message;
  RETURN jsonb_build_object('message_id', v_message.id, 'created_at', v_message.created_at);
END;
$$;

-- Patch the latest manual-address definition, including its later guard changes.
DO $address_optional$
DECLARE d text; signature text; needle text:='OR char_length(btrim(COALESCE(v_address->>''detail_address'', ''''))) NOT BETWEEN 1 AND 300';
BEGIN
 FOREACH signature IN ARRAY ARRAY['public.direct_order_public_submit(uuid,text,uuid,jsonb)','public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO d;
  IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_ANCHOR_DRIFT'; END IF;
  EXECUTE replace(d,needle,replace(needle,'BETWEEN 1 AND 300','BETWEEN 0 AND 300'));
 END LOOP;
END;
$address_optional$;

-- Count existing POS adjustments once; only unposted advances use the support refund ledger.
CREATE FUNCTION public.direct_order_refund_balance(p_request_id uuid)
RETURNS TABLE(received numeric,refunded numeric) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH f AS (SELECT * FROM public.direct_order_financials WHERE request_id=p_request_id),
 receipt_totals AS (
  SELECT COALESCE(sum(x.amount) FILTER(WHERE c.kind IS DISTINCT FROM 'delivery'),0) food,
   COALESCE(sum(x.amount) FILTER(WHERE c.kind='delivery'),0) delivery
  FROM public.direct_order_payment_receipts x LEFT JOIN public.direct_order_payment_charges c ON c.id=x.charge_id WHERE x.request_id=p_request_id
 ), payments AS (
  SELECT payment_id FROM f UNION SELECT payment_id FROM public.direct_order_payment_charges WHERE request_id=p_request_id AND payment_id IS NOT NULL
 )
 SELECT COALESCE((SELECT final_total FROM f),t.food)+t.delivery,
  COALESCE((SELECT sum(a.amount) FROM public.payment_adjustments a JOIN payments p ON p.payment_id=a.payment_id),0)
  +COALESCE((SELECT sum(unposted_amount) FROM public.direct_order_refund_records WHERE request_id=p_request_id),0)
 FROM receipt_totals t;
$$;
REVOKE ALL ON FUNCTION public.direct_order_refund_balance(uuid) FROM PUBLIC,anon,authenticated;

-- Original quoted shipping retains its existing pickup refund contract. This
-- balance covers later delivery charges, including unposted partial receipts.
CREATE FUNCTION public.direct_order_supplemental_delivery_refund_due(p_request_id uuid)
RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH charges AS MATERIALIZED (SELECT id,payment_id FROM public.direct_order_payment_charges WHERE request_id=p_request_id AND kind='delivery')
 SELECT greatest(0,
  COALESCE((SELECT sum(r.amount) FROM public.direct_order_payment_receipts r JOIN charges c ON c.id=r.charge_id),0)
  -COALESCE((SELECT sum(a.amount) FROM public.payment_adjustments a JOIN charges c ON c.payment_id=a.payment_id),0)
  -COALESCE((SELECT sum(unposted_amount) FROM public.direct_order_refund_records WHERE request_id=p_request_id AND purpose='pickup_delivery'),0));
$$;
REVOKE ALL ON FUNCTION public.direct_order_supplemental_delivery_refund_due(uuid) FROM PUBLIC,anon,authenticated;

-- The order header must include supplemental receipts and completed refunds;
-- quotes and already issued fiscal snapshots retain their original amounts.
DO $settlement_header$
DECLARE d text; paid text:='''paid_total'', f.final_total,';
 refunded text:=E'''refunded_total'', COALESCE((SELECT sum(a.amount) FROM public.payment_adjustments a\n      WHERE a.payment_id = f.payment_id), 0)';
BEGIN
 SELECT pg_get_functiondef('public.direct_order_fulfillment_context(uuid)'::regprocedure) INTO d;
 IF strpos(d,paid)=0 OR strpos(d,refunded)=0 OR strpos(d,'WHERE r.id = p_request_id;')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_VERIFICATION_FAILED';END IF;
 d:=replace(d,paid,'''paid_total'', CASE WHEN f.request_id IS NULL THEN NULL ELSE settlement.received END,');
 d:=replace(d,refunded,'''refunded_total'', settlement.refunded');
 d:=replace(d,'WHERE r.id = p_request_id;',E'CROSS JOIN public.direct_order_refund_balance(p_request_id) settlement\n  WHERE r.id = p_request_id;');
 EXECUTE d;
END;
$settlement_header$;

CREATE FUNCTION public.direct_order_pickup_support_transition() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF NEW.fulfillment_method='pickup' AND OLD.fulfillment_method='delivery' THEN
  UPDATE public.direct_order_payment_charges SET status='void' WHERE request_id=NEW.id AND kind='delivery' AND status NOT IN ('paid','void');
  NEW.delivery_fee_finalized:=true;
  NEW.support_version:=NEW.support_version+1;
 END IF;
 RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_pickup_support_transition() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER direct_order_pickup_support BEFORE UPDATE OF fulfillment_method ON public.direct_order_requests
 FOR EACH ROW EXECUTE FUNCTION public.direct_order_pickup_support_transition();

CREATE FUNCTION public.direct_order_support_context(p_request_id uuid,p_staff boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH charge_receipts AS MATERIALIZED (SELECT charge_id,sum(amount) amount FROM public.direct_order_payment_receipts WHERE request_id=p_request_id GROUP BY charge_id), receipts AS (
  SELECT COALESCE(sum(r.amount) FILTER(WHERE c.kind IS DISTINCT FROM 'delivery'),0) AS food_received,
    COALESCE(sum(r.amount) FILTER(WHERE c.kind='delivery'),0) AS delivery_received
  FROM public.direct_order_payment_receipts r LEFT JOIN public.direct_order_payment_charges c ON c.id=r.charge_id
  WHERE r.request_id=p_request_id
 ), quote AS (
  SELECT id,final_total FROM public.direct_order_quotes WHERE request_id=p_request_id AND status IN ('active','locked')
  ORDER BY version DESC LIMIT 1
 )
 SELECT jsonb_build_object('version',r.support_version,'chat_open',r.support_closed_at IS NULL,
  'delivery_fee_deferred',r.delivery_fee_deferred,'delivery_fee_finalized',r.delivery_fee_finalized,
  'food_received',CASE WHEN f.request_id IS NOT NULL THEN f.final_total ELSE v.food_received END,
  'delivery_received',v.delivery_received,'food_due',greatest(0,COALESCE(q.final_total,0)-CASE WHEN f.request_id IS NOT NULL THEN f.final_total ELSE v.food_received END),
  'unposted_advance',greatest(0,CASE WHEN f.request_id IS NULL THEN v.food_received ELSE 0 END + v.delivery_received
   -COALESCE((SELECT sum(amount) FROM public.direct_order_payment_charges WHERE request_id=r.id AND payment_id IS NOT NULL),0)
   -COALESCE((SELECT sum(unposted_amount) FROM public.direct_order_refund_records WHERE request_id=r.id),0)),
  'refund_status',r.refund_details->>'status',
  'pickup_delivery_refund_due',CASE WHEN r.fulfillment_method='pickup' THEN public.direct_order_supplemental_delivery_refund_due(r.id) ELSE 0 END,
  'refunded_total',b.refunded,'refund_due',greatest(0,b.received-b.refunded),
  'charges',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',c.id,'kind',c.kind,'amount',c.amount,'reason',c.reason,'status',c.status,
    'received',COALESCE(cr.amount,0)) ORDER BY c.created_at,c.id)
    FROM public.direct_order_payment_charges c LEFT JOIN charge_receipts cr ON cr.charge_id=c.id WHERE c.request_id=r.id),'[]'::jsonb),
  'receipts',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',v.id,'amount',v.amount,'proof_message_id',v.proof_message_id,
    'charge_id',v.charge_id,'confirmed_at',v.confirmed_at) ORDER BY v.confirmed_at,v.id)
    FROM public.direct_order_payment_receipts v WHERE v.request_id=r.id),'[]'::jsonb)
 ) || CASE WHEN p_staff THEN jsonb_build_object('invoice',r.invoice_details,'refund',r.refund_details) ELSE '{}'::jsonb END
 FROM public.direct_order_requests r LEFT JOIN public.direct_order_financials f ON f.request_id=r.id
 CROSS JOIN receipts v CROSS JOIN public.direct_order_refund_balance(p_request_id) b LEFT JOIN quote q ON true WHERE r.id=p_request_id;
$$;
REVOKE ALL ON FUNCTION public.direct_order_support_context(uuid,boolean) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.direct_order_staff_detail_v4(p_store_id uuid,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v_base jsonb;
BEGIN
 v_base:=public.direct_order_staff_detail_v3(p_store_id,p_request_id);
 RETURN v_base || jsonb_build_object('delivery',public.direct_order_fulfillment_context(p_request_id),
  'support',public.direct_order_support_context(p_request_id,true));
END;
$$;
CREATE FUNCTION public.direct_order_public_status_v5(p_session_id uuid,p_secret_hash text,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE v_base jsonb;
BEGIN
 v_base:=public.direct_order_public_status_v4(p_session_id,p_secret_hash,p_request_id);
 RETURN v_base || jsonb_build_object('delivery',public.direct_order_fulfillment_context(p_request_id),
  'support',public.direct_order_support_context(p_request_id,false));
END;
$$;

-- Versioned additive responses preserve strict existing v3/v4 clients during rollout.
REVOKE ALL ON FUNCTION public.direct_order_staff_detail_v4(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_detail_v4(uuid,uuid) TO authenticated,service_role;
REVOKE ALL ON FUNCTION public.direct_order_public_status_v5(uuid,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_status_v5(uuid,text,uuid) TO service_role;

-- A quote/charge version is the notification identity; obsolete notices are skipped.
ALTER TABLE public.direct_order_customer_events ADD COLUMN subject_id uuid;
ALTER TABLE public.direct_order_customer_events DROP CONSTRAINT direct_order_customer_events_event_kind_check;
ALTER TABLE public.direct_order_customer_events ADD CONSTRAINT direct_order_customer_events_event_kind_check
 CHECK(event_kind IN ('pickup_ready','driver_handoff','payment_request'));
ALTER TABLE public.direct_order_customer_events DROP CONSTRAINT direct_order_customer_events_request_id_event_kind_key;
CREATE UNIQUE INDEX direct_order_event_subject_unique ON public.direct_order_customer_events(request_id,event_kind,COALESCE(subject_id,'00000000-0000-0000-0000-000000000000'::uuid));
CREATE FUNCTION public.direct_order_notify_payment(p_request_id uuid,p_subject_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE r public.direct_order_requests%ROWTYPE; e uuid;
BEGIN
 SELECT * INTO r FROM public.direct_order_requests WHERE id=p_request_id FOR UPDATE;
 IF NOT FOUND OR r.state IN ('cancelled','rejected','expired') THEN RETURN; END IF;
 INSERT INTO public.direct_order_customer_events(request_id,session_id,restaurant_id,event_kind,subject_id)
 VALUES(r.id,r.session_id,r.restaurant_id,'payment_request',p_subject_id) ON CONFLICT DO NOTHING RETURNING id INTO e;
 IF e IS NULL THEN RETURN; END IF;
 INSERT INTO public.direct_order_push_deliveries(event_id,session_id,device_id)
 SELECT e,d.session_id,d.device_id FROM public.direct_order_push_devices d JOIN public.direct_order_sessions s ON s.id=d.session_id
 WHERE d.session_id=r.session_id AND d.enabled AND s.revoked_at IS NULL AND s.expires_at>now();
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_notify_payment(uuid,uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_payment_notice_trigger() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF TG_TABLE_NAME='direct_order_quotes' THEN
  PERFORM public.direct_order_notify_payment(NEW.request_id,NEW.id);
 ELSIF NEW.status IN ('pending','awaiting_consent') AND (TG_OP='INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
  PERFORM public.direct_order_notify_payment(NEW.request_id,NEW.id);
 END IF;
 RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_payment_notice_trigger() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER direct_order_quote_payment_notice AFTER INSERT ON public.direct_order_quotes FOR EACH ROW EXECUTE FUNCTION public.direct_order_payment_notice_trigger();
CREATE TRIGGER direct_order_charge_payment_notice AFTER INSERT OR UPDATE OF status ON public.direct_order_payment_charges FOR EACH ROW EXECUTE FUNCTION public.direct_order_payment_notice_trigger();
DO $push_claim$
DECLARE d text; needle text:='OR r.state<>''approved''';
BEGIN
 SELECT pg_get_functiondef('public.claim_direct_order_push_deliveries(integer)'::regprocedure) INTO d;
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_PUSH_ANCHOR_DRIFT'; END IF;
 d:=replace(d,needle,$replacement$OR (e.event_kind<>'payment_request' AND r.state<>'approved')
  OR (e.event_kind='payment_request' AND (r.state IN ('cancelled','rejected','expired') OR NOT (
   EXISTS(SELECT 1 FROM public.direct_order_quotes q WHERE q.id=e.subject_id AND q.request_id=r.id AND q.status='active' AND q.expires_at>now())
   OR EXISTS(SELECT 1 FROM public.direct_order_payment_charges c WHERE c.id=e.subject_id AND c.request_id=r.id AND c.status IN ('pending','awaiting_consent')))))$replacement$);
 EXECUTE d;
END;
$push_claim$;
-- Existing non-payment event insert uses its unique subject expression index.
DO $event_compat$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_enqueue_customer_event(uuid,text)'::regprocedure) INTO d;
 EXECUTE replace(d,'ON CONFLICT(request_id,event_kind) DO NOTHING','ON CONFLICT DO NOTHING');
END;
$event_compat$;

CREATE FUNCTION public.direct_order_sync_invoice(p_store_id uuid,p_request_id uuid,p_order_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v jsonb;
BEGIN
 SELECT invoice_details INTO v FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id;
 IF v->>'requested'='true' THEN
  PERFORM public.upsert_red_invoice_intake_minimal(p_order_id,p_store_id,'cashier',
   CASE WHEN COALESCE(v->>'legal_name','')<>'' AND COALESCE(v->>'tax_code','')<>'' AND COALESCE(v->>'address','')<>'' AND COALESCE(v->>'email','') LIKE '%@%' AND COALESCE(v->>'phone','')<>'' THEN 'ready' ELSE 'awaiting_information' END,
   NULLIF(v->>'tax_code',''),NULLIF(v->>'legal_name',''),NULLIF(v->>'address',''),NULLIF(v->>'email',''),NULLIF(v->>'phone',''),'Direct Order');
 END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_sync_invoice(uuid,uuid,uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.direct_order_record_receipt(p_store_id uuid,p_request_id uuid,p_quote_id uuid,p_proof_message_id uuid,p_amount numeric,p_bank_reference text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE r public.direct_order_requests%ROWTYPE; q public.direct_order_quotes%ROWTYPE;
 m public.direct_order_messages%ROWTYPE; c public.direct_order_payment_charges%ROWTYPE;
 v_existing public.direct_order_payment_receipts%ROWTYPE; v_total numeric; v_due numeric; v_result jsonb;
 v_order public.orders%ROWTYPE; v_payment public.payments%ROWTYPE; v_fee_pretax numeric; v_vat numeric; v_rate numeric;
BEGIN
 PERFORM public.direct_order_require_actor(p_store_id,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 PERFORM pg_advisory_xact_lock(hashtextextended('direct-order-approval:'||p_request_id::text,0));
 SELECT * INTO r FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 SELECT * INTO v_existing FROM public.direct_order_payment_receipts WHERE proof_message_id=p_proof_message_id;
 IF FOUND THEN
  IF v_existing.request_id<>r.id OR v_existing.amount IS DISTINCT FROM p_amount OR v_existing.bank_reference IS DISTINCT FROM btrim(p_bank_reference) THEN
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
  IF EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=r.id) THEN RAISE EXCEPTION 'DIRECT_ORDER_ALREADY_PAID'; END IF;
  SELECT q.final_total-COALESCE(sum(x.amount),0) INTO v_due FROM public.direct_order_payment_receipts x
   LEFT JOIN public.direct_order_payment_charges z ON z.id=x.charge_id WHERE x.request_id=r.id AND z.kind IS DISTINCT FROM 'delivery';
 END IF;
 IF EXISTS(SELECT 1 FROM public.direct_order_payment_receipts WHERE request_id=r.id AND bank_reference=btrim(p_bank_reference)) THEN RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED'; END IF;
 IF p_amount>v_due THEN RAISE EXCEPTION 'DIRECT_ORDER_AMOUNT_EXCEEDS_DUE'; END IF;
 INSERT INTO public.direct_order_payment_receipts(request_id,restaurant_id,charge_id,quote_id,proof_message_id,amount,bank_reference,confirmed_by)
 VALUES(r.id,p_store_id,c.id,q.id,m.id,p_amount,btrim(p_bank_reference),auth.uid());
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'direct_order_receipt_confirmed','direct_order_requests',r.id,
  jsonb_build_object('amount',p_amount,'proof_message_id',m.id,'charge_id',c.id,'actual_bank_receipt_confirmed',true));
 IF c.kind='delivery' AND p_amount=v_due THEN
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
 ELSIF c.kind IS DISTINCT FROM 'delivery' AND p_amount=v_due THEN
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
REVOKE ALL ON FUNCTION public.direct_order_record_receipt(uuid,uuid,uuid,uuid,numeric,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_record_receipt(uuid,uuid,uuid,uuid,numeric,text) TO authenticated,service_role;

CREATE FUNCTION public.direct_order_staff_support_action(p_store_id uuid,p_request_id uuid,p_expected_version integer,p_action text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE r public.direct_order_requests%ROWTYPE; q public.direct_order_quotes%ROWTYPE; c public.direct_order_payment_charges%ROWTYPE;
 v_existing_refund public.direct_order_refund_records%ROWTYPE;
 v_amount numeric; v_received numeric; v_refunded numeric; v_fin public.direct_order_financials%ROWTYPE; v_left numeric; v_part numeric;
BEGIN
 PERFORM public.direct_order_require_actor(p_store_id,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT * INTO r FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_INPUT_INVALID'; END IF;
 IF p_action IN ('refund_complete','refund_delivery_complete') THEN
  SELECT * INTO v_existing_refund FROM public.direct_order_refund_records WHERE id=(p_payload->>'operation_id')::uuid;
  IF FOUND THEN
   IF v_existing_refund.request_id<>r.id OR v_existing_refund.purpose IS DISTINCT FROM (CASE WHEN p_action='refund_delivery_complete' THEN 'pickup_delivery' ELSE 'cancellation' END)
    OR v_existing_refund.amount IS DISTINCT FROM (p_payload->>'amount')::numeric
    OR v_existing_refund.reference IS DISTINCT FROM btrim(p_payload->>'reference') THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_CHANGED'; END IF;
   RETURN public.direct_order_support_context(r.id,true);
  END IF;
 END IF;
 IF r.support_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_CHANGED'; END IF;
 IF p_payload IS NULL OR jsonb_typeof(p_payload)<>'object' THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_INPUT_INVALID'; END IF;
 SELECT * INTO v_fin FROM public.direct_order_financials WHERE request_id=r.id;
 IF p_action='invoice' THEN
  IF EXISTS(SELECT 1 FROM jsonb_object_keys(p_payload) k WHERE k NOT IN ('requested','tax_code','legal_name','address','email','phone'))
   OR EXISTS(SELECT 1 FROM jsonb_each(p_payload) e WHERE e.key<>'requested' AND jsonb_typeof(e.value)<>'string')
   OR jsonb_typeof(p_payload->'requested') IS DISTINCT FROM 'boolean'
   OR char_length(COALESCE(p_payload->>'tax_code',''))>30 OR char_length(COALESCE(p_payload->>'legal_name',''))>300
   OR char_length(COALESCE(p_payload->>'address',''))>500 OR char_length(COALESCE(p_payload->>'email',''))>254
   OR char_length(COALESCE(p_payload->>'phone',''))>30 THEN RAISE EXCEPTION 'DIRECT_ORDER_INVOICE_INVALID'; END IF;
  UPDATE public.direct_order_requests SET invoice_details=p_payload WHERE id=r.id;
  IF v_fin.order_id IS NOT NULL THEN PERFORM public.direct_order_sync_invoice(p_store_id,r.id,v_fin.order_id); END IF;
  FOR c IN SELECT * FROM public.direct_order_payment_charges WHERE request_id=r.id AND order_id IS NOT NULL LOOP
   PERFORM public.direct_order_sync_invoice(p_store_id,r.id,c.order_id);
  END LOOP;
 ELSIF p_action='defer_delivery_fee' THEN
  IF r.state<>'awaiting_quote' OR v_fin.request_id IS NOT NULL OR (r.fulfillment_method<>'delivery' OR r.fulfillment_type='pickup') THEN RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;
  IF jsonb_typeof(p_payload->'enabled') IS DISTINCT FROM 'boolean' THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_INPUT_INVALID'; END IF;
  UPDATE public.direct_order_requests SET delivery_fee_deferred=(p_payload->>'enabled')::boolean,
   delivery_fee_finalized=NOT (p_payload->>'enabled')::boolean WHERE id=r.id;
 ELSIF p_action='charge' THEN
  IF r.state IN ('cancelled','rejected','expired') OR (r.fulfillment_method='pickup' OR r.fulfillment_type='pickup') AND p_payload->>'kind'='delivery'
   OR EXISTS(SELECT 1 FROM public.direct_delivery_fulfillment_tickets WHERE request_id=r.id AND status IN ('dispatched','completed','cancelled')) THEN
   RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;
  v_amount:=(p_payload->>'amount')::numeric;
  IF v_amount IS NULL OR v_amount<=0 OR v_amount<>trunc(v_amount) OR v_amount::text IN ('NaN','Infinity','-Infinity') OR char_length(btrim(COALESCE(p_payload->>'reason',''))) NOT BETWEEN 1 AND 500 THEN
   RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_INVALID'; END IF;
  SELECT * INTO q FROM public.direct_order_quotes WHERE request_id=r.id AND status='locked' ORDER BY version DESC LIMIT 1;
  IF p_payload->>'kind'='food_balance' THEN
   IF v_fin.request_id IS NOT NULL OR q.id IS NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;
   SELECT COALESCE(sum(x.amount),0) INTO v_received FROM public.direct_order_payment_receipts x LEFT JOIN public.direct_order_payment_charges z ON z.id=x.charge_id
    WHERE x.request_id=r.id AND z.kind IS DISTINCT FROM 'delivery';
   IF v_amount IS DISTINCT FROM q.final_total-v_received THEN RAISE EXCEPTION 'DIRECT_ORDER_AMOUNT_MISMATCH'; END IF;
  ELSIF p_payload->>'kind'='delivery' THEN
   IF v_fin.request_id IS NULL OR (r.fulfillment_method<>'delivery' OR r.fulfillment_type='pickup') OR v_fin.delivery_payment_mode<>'store_prepaid'
    OR EXISTS(SELECT 1 FROM public.direct_order_payment_charges WHERE request_id=r.id AND kind='delivery' AND status NOT IN ('paid','void')) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;
  ELSE RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_INVALID'; END IF;
  INSERT INTO public.direct_order_payment_charges(request_id,restaurant_id,kind,amount,reason,status,created_by)
   VALUES(r.id,p_store_id,p_payload->>'kind',v_amount,btrim(p_payload->>'reason'),
   CASE WHEN p_payload->>'kind'='delivery' THEN 'awaiting_consent' ELSE 'pending' END,auth.uid());
  IF p_payload->>'kind'='delivery' THEN UPDATE public.direct_order_requests SET delivery_fee_finalized=true WHERE id=r.id; END IF;
 ELSIF p_action='no_delivery_fee' THEN
  IF r.delivery_fee_finalized OR v_fin.request_id IS NULL OR EXISTS(SELECT 1 FROM public.direct_order_payment_charges WHERE request_id=r.id AND kind='delivery' AND status NOT IN ('paid','void')) THEN
   RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;
  UPDATE public.direct_order_requests SET delivery_fee_finalized=true WHERE id=r.id;
 ELSIF p_action='cancel_order' THEN
  IF r.state<>'approved' OR EXISTS(SELECT 1 FROM public.direct_order_dispatches WHERE request_id=r.id)
   OR EXISTS(SELECT 1 FROM public.direct_delivery_fulfillment_tickets WHERE request_id=r.id AND status IN ('dispatched','completed')) THEN
   RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;
  UPDATE public.direct_delivery_fulfillment_tickets SET status='cancelled',version=version+1,cancelled_at=now(),updated_at=now(),updated_by=auth.uid() WHERE request_id=r.id;
  UPDATE public.direct_order_requests SET state='cancelled',updated_at=now() WHERE id=r.id;
  UPDATE public.direct_order_payment_charges SET status='void' WHERE request_id=r.id AND status NOT IN ('paid','void');
 ELSIF p_action='refund_details' THEN
  IF r.state NOT IN ('cancelled','rejected','expired') THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_NOT_ALLOWED'; END IF;
  IF char_length(COALESCE(p_payload->>'bank',''))>100 OR char_length(COALESCE(p_payload->>'account',''))>100 OR char_length(COALESCE(p_payload->>'holder',''))>200
    OR char_length(COALESCE(p_payload->>'note',''))>500 THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_INPUT_INVALID'; END IF;
  UPDATE public.direct_order_requests SET refund_details=jsonb_build_object('bank',p_payload->>'bank','account',p_payload->>'account','holder',p_payload->>'holder','note',p_payload->>'note','status','pending') WHERE id=r.id;
 ELSIF p_action='refund_delivery_complete' THEN
  IF r.state<>'approved' OR r.fulfillment_method<>'pickup'
   OR NOT EXISTS(SELECT 1 FROM public.direct_order_pickup_offers WHERE request_id=r.id AND status='accepted')
   OR char_length(btrim(COALESCE(p_payload->>'reference',''))) NOT BETWEEN 1 AND 200 THEN
   RAISE EXCEPTION 'DIRECT_ORDER_REFUND_NOT_ALLOWED'; END IF;
  v_amount:=(p_payload->>'amount')::numeric;
  v_received:=public.direct_order_supplemental_delivery_refund_due(r.id);
  IF v_amount IS NULL OR v_amount<=0 OR v_amount<>trunc(v_amount) OR v_amount::text IN ('NaN','Infinity','-Infinity') OR v_amount>v_received THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_AMOUNT_INVALID'; END IF;
  v_left:=v_amount;
  FOR c IN SELECT * FROM public.direct_order_payment_charges WHERE request_id=r.id AND kind='delivery' AND payment_id IS NOT NULL ORDER BY created_at,id LOOP
   EXIT WHEN v_left<=0;
   SELECT greatest(0,c.amount-COALESCE(sum(amount),0)) INTO v_part FROM public.payment_adjustments WHERE payment_id=c.payment_id;
   v_part:=least(v_left,v_part);
   IF v_part>0 THEN PERFORM public.record_payment_adjustment(c.payment_id,'refund',v_part,p_payload->>'reference'); v_left:=v_left-v_part; END IF;
  END LOOP;
  INSERT INTO public.direct_order_refund_records(id,request_id,restaurant_id,amount,unposted_amount,purpose,reference,recorded_by)
   VALUES((p_payload->>'operation_id')::uuid,r.id,p_store_id,v_amount,v_left,'pickup_delivery',btrim(p_payload->>'reference'),auth.uid());
 ELSIF p_action='refund_complete' THEN
  IF r.state NOT IN ('cancelled','rejected','expired') OR char_length(btrim(COALESCE(p_payload->>'reference',''))) NOT BETWEEN 1 AND 200 THEN
   RAISE EXCEPTION 'DIRECT_ORDER_REFUND_NOT_ALLOWED'; END IF;
  v_amount:=(p_payload->>'amount')::numeric;
  SELECT received,refunded INTO v_received,v_refunded FROM public.direct_order_refund_balance(r.id);
  IF v_amount IS NULL OR v_amount<=0 OR v_amount<>trunc(v_amount) OR v_amount::text IN ('NaN','Infinity','-Infinity') OR v_amount>v_received-v_refunded THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_AMOUNT_INVALID'; END IF;
  v_left:=v_amount;
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
  INSERT INTO public.direct_order_refund_records(id,request_id,restaurant_id,amount,unposted_amount,reference,recorded_by)
   VALUES((p_payload->>'operation_id')::uuid,r.id,p_store_id,v_amount,v_left,btrim(p_payload->>'reference'),auth.uid());
  UPDATE public.direct_order_requests SET refund_details=refund_details||jsonb_build_object('status',CASE WHEN v_amount=v_received-v_refunded THEN 'completed' ELSE 'partial' END) WHERE id=r.id;
 ELSIF p_action='close_chat' THEN
  SELECT received,refunded INTO v_received,v_refunded FROM public.direct_order_refund_balance(r.id);
  IF r.state NOT IN ('cancelled','rejected','expired') OR v_received>v_refunded THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_PENDING'; END IF;
  UPDATE public.direct_order_requests SET support_closed_at=now() WHERE id=r.id;
 ELSE RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_INPUT_INVALID'; END IF;
 UPDATE public.direct_order_requests SET support_version=support_version+1 WHERE id=r.id;
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'direct_order_support_'||p_action,'direct_order_requests',r.id,
  jsonb_build_object('store_id',p_store_id,'previous_version',r.support_version));
 RETURN public.direct_order_support_context(r.id,true);
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_staff_support_action(uuid,uuid,integer,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_support_action(uuid,uuid,integer,text,jsonb) TO authenticated,service_role;

CREATE FUNCTION public.direct_order_public_charge_consent(p_session_id uuid,p_secret_hash text,p_request_id uuid,p_charge_id uuid,p_accept boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE s public.direct_order_sessions%ROWTYPE; r public.direct_order_requests%ROWTYPE; c public.direct_order_payment_charges%ROWTYPE;
BEGIN
 s:=public.direct_order_validate_session(p_session_id,p_secret_hash);
 SELECT * INTO r FROM public.direct_order_requests WHERE id=p_request_id AND session_id=s.id AND restaurant_id=s.restaurant_id FOR UPDATE;
 IF NOT FOUND OR r.state<>'approved' THEN RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;
 SELECT * INTO c FROM public.direct_order_payment_charges WHERE id=p_charge_id AND request_id=r.id FOR UPDATE;
 IF NOT FOUND OR c.status NOT IN ('awaiting_consent','pending','void') THEN RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;
 IF p_accept IS NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;
 IF c.status<>'awaiting_consent' THEN
  IF (c.status='pending' AND NOT p_accept) OR (c.status='void' AND p_accept) THEN RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;
  RETURN public.direct_order_support_context(r.id,false);
 END IF;
 UPDATE public.direct_order_payment_charges SET status=CASE WHEN p_accept THEN 'pending' ELSE 'void' END,consented_at=now() WHERE id=c.id;
 IF NOT p_accept THEN UPDATE public.direct_order_requests SET delivery_fee_finalized=false WHERE id=r.id; END IF;
 UPDATE public.direct_order_requests SET support_version=support_version+1 WHERE id=r.id;
 RETURN public.direct_order_support_context(r.id,false);
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_public_charge_consent(uuid,text,uuid,uuid,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_charge_consent(uuid,text,uuid,uuid,boolean) TO service_role;

CREATE FUNCTION public.direct_order_assert_settled(p_request_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM public.direct_order_requests WHERE id=p_request_id AND (NOT delivery_fee_finalized
   OR fulfillment_method='pickup' AND public.direct_order_supplemental_delivery_refund_due(id)>0))
  OR EXISTS(SELECT 1 FROM public.direct_order_payment_charges WHERE request_id=p_request_id AND status NOT IN ('paid','void')) THEN
  RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_PENDING'; END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_assert_settled(uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_settlement_gate() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF TG_TABLE_NAME='direct_order_dispatches' THEN
  PERFORM public.direct_order_assert_settled(NEW.request_id);
  IF EXISTS(SELECT 1 FROM public.direct_order_payment_charges WHERE request_id=NEW.request_id AND kind='delivery' AND status='paid') THEN
   SELECT NEW.customer_delivery_fee+COALESCE(sum(amount),0) INTO NEW.customer_delivery_fee FROM public.direct_order_payment_charges WHERE request_id=NEW.request_id AND kind='delivery' AND status='paid';
   NEW.fee_variance:=CASE WHEN NEW.actual_grab_fee IS NULL THEN NULL ELSE NEW.customer_delivery_fee-NEW.actual_grab_fee END;
  END IF;
 ELSIF NEW.status IN ('dispatched','completed') AND NEW.status IS DISTINCT FROM OLD.status THEN PERFORM public.direct_order_assert_settled(NEW.request_id); END IF;
 RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_settlement_gate() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER direct_order_dispatch_settlement BEFORE INSERT ON public.direct_order_dispatches FOR EACH ROW EXECUTE FUNCTION public.direct_order_settlement_gate();
CREATE TRIGGER direct_order_completion_settlement BEFORE UPDATE OF status ON public.direct_delivery_fulfillment_tickets FOR EACH ROW EXECUTE FUNCTION public.direct_order_settlement_gate();
-- Deferred food quotes contain no provisional shipping fee, preserving VAT totals.
DO $deferred_quote$
DECLARE d text; needle text:='  v_mode :=';
BEGIN
 SELECT pg_get_functiondef('public.direct_order_staff_quote_with_payment_mode(uuid,uuid,numeric,text,text)'::regprocedure) INTO d;
 IF strpos(d,'BEGIN')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_ANCHOR_DRIFT'; END IF;
 d:=replace(d,E'BEGIN\n',$body$BEGIN
  IF EXISTS(SELECT 1 FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id AND delivery_fee_deferred) THEN
    p_delivery_fee_total:=0;
    p_delivery_payment_mode:='store_prepaid';
  END IF;
$body$);
 EXECUTE d;
END;
$deferred_quote$;

CREATE FUNCTION public.direct_order_commit_attachment(p_request_id uuid,p_store_id uuid,p_sender text,p_actor uuid,p_path text,p_filename text,p_charge_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE r public.direct_order_requests%ROWTYPE; c public.direct_order_payment_charges%ROWTYPE; q public.direct_order_quotes%ROWTYPE; m public.direct_order_messages%ROWTYPE;
BEGIN
 SELECT * INTO r FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id FOR UPDATE;
 IF NOT FOUND OR r.support_closed_at IS NOT NULL OR p_sender NOT IN ('cashier','customer')
  OR p_path NOT LIKE p_store_id::text||'/'||p_request_id::text||'/%'
  OR char_length(COALESCE(p_filename,'')) NOT BETWEEN 1 AND 255 THEN RAISE EXCEPTION 'DIRECT_ORDER_ATTACHMENT_INVALID'; END IF;
 SELECT * INTO m FROM public.direct_order_messages WHERE attachment_storage_path=p_path;
 IF FOUND THEN
  IF m.request_id<>r.id OR m.sender_type<>p_sender OR m.metadata->>'charge_id' IS DISTINCT FROM p_charge_id::text THEN RAISE EXCEPTION 'DIRECT_ORDER_ATTACHMENT_INVALID'; END IF;
  RETURN jsonb_build_object('message_id',m.id,'created_at',m.created_at);
 END IF;
 IF p_sender='customer' THEN
  IF p_charge_id IS NULL OR r.state IN ('cancelled','rejected','expired') THEN RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;
  SELECT * INTO c FROM public.direct_order_payment_charges WHERE id=p_charge_id AND request_id=r.id AND status IN ('pending','review') FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_CHARGE_CHANGED'; END IF;
  SELECT * INTO q FROM public.direct_order_quotes WHERE request_id=r.id AND status='locked' ORDER BY version DESC LIMIT 1;
  IF q.id IS NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_CHANGED'; END IF;
 END IF;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,sender_auth_id,message_type,body,attachment_storage_path,metadata,created_at)
 VALUES(r.id,p_store_id,p_sender,p_actor,CASE WHEN p_sender='customer' THEN 'payment_proof' ELSE 'attachment' END,p_filename,p_path,
  jsonb_build_object('attachment_bucket','direct-order-chat','filename',p_filename,'charge_id',p_charge_id,'quote_id',q.id,'quote_version',q.version),clock_timestamp()) RETURNING * INTO m;
 IF c.id IS NOT NULL THEN UPDATE public.direct_order_payment_charges SET status='review' WHERE id=c.id; END IF;
 RETURN jsonb_build_object('message_id',m.id,'created_at',m.created_at);
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_commit_attachment(uuid,uuid,text,uuid,text,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_commit_attachment(uuid,uuid,text,uuid,text,text,uuid) TO service_role;
-- Use a checked version of the current snapshot enrichment, preserving routing.
DO $suppress_early_receipt$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.enqueue_direct_order_customer_receipt_after_payment()'::regprocedure) INTO d;
 IF strpos(d,'BEGIN')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_RECEIPT_ANCHOR_DRIFT'; END IF;
 EXECUTE replace(d,E'BEGIN\n',$body$BEGIN
  IF EXISTS(SELECT 1 FROM public.direct_order_requests WHERE id=NEW.request_id AND delivery_fee_deferred) THEN RETURN NEW; END IF;
$body$);
END;
$suppress_early_receipt$;
CREATE FUNCTION public.direct_order_settled_receipt_payload(p_request_id uuid,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE extra jsonb; amount numeric; pretax numeric; vat numeric; payments jsonb; refunds numeric; pickup boolean;
BEGIN
 PERFORM public.direct_order_assert_settled(p_request_id);
 SELECT fulfillment_method='pickup' INTO pickup FROM public.direct_order_requests WHERE id=p_request_id;
 SELECT COALESCE(sum(i.paying_amount_inc_tax),0),COALESCE(sum(i.unit_price*i.quantity),0),COALESCE(sum(i.vat_amount),0),
  COALESCE(jsonb_agg(jsonb_build_object('label',i.label,'quantity',i.quantity,'unit_price',i.unit_price,'line_total',i.unit_price*i.quantity,
   'paying_amount_inc_tax',i.paying_amount_inc_tax,'vat_amount',i.vat_amount,'item_type',i.item_type,'is_service_item',false,'item_id',i.id) ORDER BY c.created_at,c.id) FILTER(WHERE NOT pickup),'[]'::jsonb)
 INTO amount,pretax,vat,extra FROM public.direct_order_payment_charges c JOIN public.order_items i ON i.order_id=c.order_id AND i.item_type='service_charge'
 WHERE c.request_id=p_request_id AND c.kind='delivery' AND c.status='paid';
 SELECT COALESCE(jsonb_agg(jsonb_build_object('method',p.method,'amount',p.amount_portion,'is_revenue',p.is_revenue) ORDER BY p.created_at,p.id),'[]'::jsonb)
 INTO payments FROM public.direct_order_payment_charges c JOIN public.payments p ON p.id=c.payment_id WHERE c.request_id=p_request_id AND c.kind='delivery' AND c.status='paid';
 WITH paid AS (SELECT payment_id FROM public.direct_order_financials WHERE request_id=p_request_id
  UNION SELECT payment_id FROM public.direct_order_payment_charges WHERE request_id=p_request_id AND payment_id IS NOT NULL)
 SELECT COALESCE(sum(a.amount),0) INTO refunds FROM public.payment_adjustments a JOIN paid p ON p.payment_id=a.payment_id;
 RETURN p_payload||jsonb_build_object('items',COALESCE(p_payload->'items','[]'::jsonb)||extra,
  'total_amount',COALESCE((p_payload->>'total_amount')::numeric,0)+amount,
  'received_amount',COALESCE((p_payload->>'received_amount')::numeric,(p_payload->>'total_amount')::numeric,0)+amount,
  'subtotal_amount',COALESCE((p_payload->>'subtotal_amount')::numeric,0)+pretax,
  'service_charge_amount',COALESCE((p_payload->>'service_charge_amount')::numeric,0)+amount,
  'vat_amount',COALESCE((p_payload->>'vat_amount')::numeric,0)+vat,
  'refunded_total',refunds,
  'payments',COALESCE(p_payload->'payments','[]'::jsonb)||payments,'direct_order_settlement',true);
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_settled_receipt_payload(uuid,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_final_receipt_enrichment() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE r uuid;
BEGIN
 SELECT request_id INTO r FROM public.direct_order_financials WHERE order_id=NEW.order_id AND restaurant_id=NEW.restaurant_id;
 IF r IS NULL OR NEW.copy_type<>'receipt' THEN RETURN NEW; END IF;
 NEW.payload:=public.direct_order_settled_receipt_payload(r,NEW.payload);
 RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_final_receipt_enrichment() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zzz_direct_order_final_receipt BEFORE INSERT ON public.print_jobs FOR EACH ROW EXECUTE FUNCTION public.direct_order_final_receipt_enrichment();
CREATE FUNCTION public.direct_order_final_digital_receipt_enrichment() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE r uuid;
BEGIN
 SELECT request_id INTO r FROM public.direct_order_financials WHERE order_id=NEW.order_id AND restaurant_id=NEW.restaurant_id;
 IF r IS NULL OR NEW.combined_payment_group_id IS NOT NULL THEN RETURN NEW; END IF;
 NEW.snapshot:=public.direct_order_settled_receipt_payload(r,NEW.snapshot);
 RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_final_digital_receipt_enrichment() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zzz_direct_order_final_digital_receipt BEFORE INSERT ON public.digital_receipts FOR EACH ROW EXECUTE FUNCTION public.direct_order_final_digital_receipt_enrichment();

-- Queue the consolidated customer receipt when the settled order completes.
-- Printer/RPC permission failures remain visible in audit and can be retried by
-- the cashier; they must not roll back a completed kitchen handoff.
CREATE FUNCTION public.direct_order_queue_final_receipt() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE order_id uuid;
BEGIN
 IF NEW.status<>'completed' OR NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
 SELECT f.order_id INTO order_id FROM public.direct_order_financials f JOIN public.direct_order_requests r ON r.id=f.request_id
 WHERE f.request_id=NEW.request_id AND (r.delivery_fee_deferred OR EXISTS(SELECT 1 FROM public.direct_order_payment_charges c WHERE c.request_id=r.id AND c.kind='delivery' AND c.status='paid'));
 IF order_id IS NULL THEN RETURN NEW; END IF;
 BEGIN
  PERFORM public.enqueue_receipt_print_job(order_id,true);
 EXCEPTION WHEN OTHERS THEN
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
  VALUES(auth.uid(),'direct_order_final_receipt_queue_failed','direct_order_requests',NEW.request_id,
   jsonb_build_object('order_id',order_id,'store_id',NEW.restaurant_id,'error_code','CUSTOMER_RECEIPT_QUEUE_FAILED'));
 END;
 RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_queue_final_receipt() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER direct_order_final_receipt_completed AFTER UPDATE OF status ON public.direct_delivery_fulfillment_tickets
 FOR EACH ROW EXECUTE FUNCTION public.direct_order_queue_final_receipt();
-- Keep cancelled/expired conversations visible across business days until staff closes support.
-- This uses a filter on the request row; no per-list-item detail calls are added.
DO $support_list$
DECLARE d text; needle text:=E'AND (r.created_at>=v_day_start';
BEGIN
 SELECT pg_get_functiondef('public.direct_order_staff_list_v3(uuid,text[],integer,text)'::regprocedure) INTO d;
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_LIST_ANCHOR_DRIFT'; END IF;
 d:=replace(d,needle,E'AND ((r.state IN (''cancelled'',''rejected'',''expired'') AND r.support_closed_at IS NULL) OR r.created_at>=v_day_start');
 EXECUTE d;
END;
$support_list$;

DO $support_retention$
DECLARE d text; needle text:='AND request_row.pii_purged_at IS NULL';
BEGIN
 SELECT pg_get_functiondef('public.direct_order_cleanup_expired_pii(uuid[])'::regprocedure) INTO d;
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_CLEANUP_ANCHOR_DRIFT'; END IF;
 d:=replace(d,needle,needle||E'\n AND (request_row.state=''approved'' OR request_row.support_closed_at IS NOT NULL)\n AND NOT EXISTS(SELECT 1 FROM public.direct_order_payment_charges c WHERE c.request_id=request_row.id AND c.status NOT IN (''paid'',''void''))');
 d:=replace(d,'WHERE message.request_id = ANY(p_request_ids);',E'WHERE message.request_id = ANY(p_request_ids) AND NOT EXISTS(SELECT 1 FROM public.direct_order_payment_receipts r WHERE r.proof_message_id=message.id);\n UPDATE public.direct_order_messages message SET message_type=''system'',body=''DIRECT_ORDER_EVIDENCE_PURGED'',attachment_storage_path=NULL,metadata=''{}''::jsonb,sender_auth_id=NULL WHERE message.request_id=ANY(p_request_ids) AND EXISTS(SELECT 1 FROM public.direct_order_payment_receipts r WHERE r.proof_message_id=message.id);');
 d:=replace(d,'SET customer_note = NULL, pii_purged_at = now()',E'SET customer_note = NULL, invoice_details=''{}''::jsonb, refund_details=''{}''::jsonb, pii_purged_at = now()');
 EXECUTE d;
 SELECT pg_get_functiondef('public.direct_order_cleanup_candidates(integer)'::regprocedure) INTO d;
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_CLEANUP_ANCHOR_DRIFT'; END IF;
 d:=replace(d,needle,needle||E'\n AND (request_row.state=''approved'' OR request_row.support_closed_at IS NOT NULL)\n AND NOT EXISTS(SELECT 1 FROM public.direct_order_payment_charges c WHERE c.request_id=request_row.id AND c.status NOT IN (''paid'',''void''))');
 d:=replace(d,'''proof_paths'', candidate.proof_paths', '''proof_paths'', candidate.proof_paths, ''chat_paths'',candidate.chat_paths');
 d:=replace(d,'AND message.attachment_storage_path IS NOT NULL',E'AND message.attachment_storage_path IS NOT NULL AND message.metadata->>''attachment_bucket'' IS DISTINCT FROM ''direct-order-chat''');
 d:=replace(d,'AS proof_paths',E'AS proof_paths, COALESCE((SELECT jsonb_agg(message.attachment_storage_path) FROM public.direct_order_messages message WHERE message.request_id=request_row.id AND message.metadata->>''attachment_bucket''=''direct-order-chat'' AND message.attachment_storage_path IS NOT NULL),''[]''::jsonb) AS chat_paths');
 EXECUTE d;
END;
$support_retention$;

-- Supplemental delivery is revenue in the same customer-order analytics row.
DO $support_analytics$
DECLARE d text; needle text:='FROM public.direct_order_financials financial';
BEGIN
 SELECT pg_get_functiondef('public.direct_order_analytics(uuid,date,date)'::regprocedure) INTO d;
 IF strpos(d,needle)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_ANALYTICS_ANCHOR_DRIFT'; END IF;
 d:=replace(d,'financial.final_total','(financial.final_total+COALESCE(supplement.amount,0))');
 d:=replace(d,'financial.delivery_fee_total','(financial.delivery_fee_total+COALESCE(supplement.amount,0))');
 d:=replace(d,needle,needle||E'\n LEFT JOIN (SELECT request_id,sum(amount) amount FROM public.direct_order_payment_charges WHERE restaurant_id=p_store_id AND payment_id IS NOT NULL GROUP BY request_id) supplement ON supplement.request_id=financial.request_id');
 EXECUTE d;
END;
$support_analytics$;

-- Cashiers use the receipt ledger; internal full-amount approval remains a single atomic anchor.
REVOKE EXECUTE ON FUNCTION public.direct_order_approve_photo_payment(uuid,uuid,numeric,uuid,uuid) FROM authenticated;

DO $verify$
BEGIN
 IF md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure)) IS DISTINCT FROM current_setting('direct_order_support.payment_anchor') THEN
  RAISE EXCEPTION 'DIRECT_ORDER_PAYMENT_ANCHOR_CHANGED';
 END IF;
 IF has_function_privilege('anon','public.direct_order_record_receipt(uuid,uuid,uuid,uuid,numeric,text)','EXECUTE')
  OR has_function_privilege('authenticated','public.direct_order_approve_photo_payment(uuid,uuid,numeric,uuid,uuid)','EXECUTE')
  OR has_function_privilege('authenticated','public.direct_order_support_context(uuid,boolean)','EXECUTE')
  OR has_table_privilege('authenticated','public.direct_order_payment_receipts','SELECT')
  OR to_regprocedure('public.direct_order_assert_settled(uuid)') IS NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_SUPPORT_VERIFICATION_FAILED'; END IF;
END;
$verify$;
COMMIT;
