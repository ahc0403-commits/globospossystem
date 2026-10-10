-- Reviewed atomic release of recipient delivery, POS buyers/ledger, ESGOO,
-- and the authorized data-access improvements. Individual source migrations
-- remain reviewable; apply this bundle once through deploy_pos_production.sh.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
CREATE TEMP TABLE pos_release_anchors ON COMMIT DROP AS
 SELECT md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure)) AS payment,
 (SELECT md5(COALESCE(string_agg(to_jsonb(f)::text,'' ORDER BY f.request_id),'')) FROM public.direct_order_financials f) AS financials,
 (SELECT md5(COALESCE(string_agg(snapshot::text,'' ORDER BY id),'')) FROM public.digital_receipts) AS issued_receipts;

-- COMPONENT 20261010050000_direct_order_recipient_delivery.sql SHA256 bce5f95dcd51b2a918ca2146a174b095d5327faaa35dbad3198f1215625c6be8
-- Recipient pays the courier; booking is separate from physical handoff.
-- production-gate: self-verifying

SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';

-- Existing finalized requests keep their policy. No financial rows are rewritten.
ALTER TABLE public.direct_order_requests ADD COLUMN delivery_policy_version integer NOT NULL DEFAULT 1
 CHECK(delivery_policy_version IN (1,2));
UPDATE public.direct_order_requests r SET delivery_policy_version=2,
 delivery_fee_deferred=false,delivery_fee_finalized=true
WHERE r.state='awaiting_quote' AND NOT EXISTS(
 SELECT 1 FROM public.direct_order_quotes q WHERE q.request_id=r.id AND q.amount_finalized_at IS NOT NULL)
 AND NOT EXISTS(SELECT 1 FROM public.direct_order_financials f WHERE f.request_id=r.id);
UPDATE public.direct_order_quotes q SET delivery_payment_mode=CASE WHEN r.fulfillment_type='pickup' THEN 'not_applicable' ELSE 'customer_direct' END,delivery_fee_pretax=0,delivery_fee_vat=0,
 delivery_fee_total=0,final_total=q.menu_total+q.service_charge_total
FROM public.direct_order_requests r WHERE q.request_id=r.id AND r.delivery_policy_version=2 AND q.amount_finalized_at IS NULL;
ALTER TABLE public.direct_order_requests ALTER COLUMN delivery_policy_version SET DEFAULT 2;
ALTER TABLE public.direct_delivery_fulfillment_tickets ADD COLUMN cooking_completed_at timestamptz;

CREATE FUNCTION public.direct_order_recipient_request_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
BEGIN
 IF TG_OP='INSERT' THEN NEW.delivery_policy_version:=2;
 ELSIF NEW.delivery_policy_version IS DISTINCT FROM OLD.delivery_policy_version THEN
  RAISE EXCEPTION 'DIRECT_ORDER_DELIVERY_POLICY_LOCKED';
 END IF;
 IF NEW.delivery_policy_version=2 THEN
  NEW.delivery_fee_deferred:=false;NEW.delivery_fee_finalized:=true;
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER direct_order_recipient_request_guard BEFORE INSERT OR UPDATE ON public.direct_order_requests
 FOR EACH ROW EXECUTE FUNCTION public.direct_order_recipient_request_guard();
REVOKE ALL ON FUNCTION public.direct_order_recipient_request_guard() FROM PUBLIC,anon,authenticated;

ALTER FUNCTION public.direct_order_staff_quote_with_payment_mode(uuid,uuid,numeric,text,text)
 RENAME TO direct_order_quote_before_recipient;
REVOKE ALL ON FUNCTION public.direct_order_quote_before_recipient(uuid,uuid,numeric,text,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_staff_quote_with_payment_mode(p_store_id uuid,p_request_id uuid,p_delivery_fee_total numeric,
 p_cashier_note text DEFAULT NULL,p_delivery_payment_mode text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE r public.direct_order_requests%ROWTYPE;mode text;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 mode:=COALESCE(p_delivery_payment_mode,CASE WHEN r.fulfillment_type='pickup' THEN 'not_applicable' WHEN r.delivery_policy_version=1 THEN 'store_prepaid' ELSE 'customer_direct' END);
 IF r.delivery_policy_version=2 AND (mode IS DISTINCT FROM CASE WHEN r.fulfillment_type='pickup' THEN 'not_applicable' ELSE 'customer_direct' END
  OR p_delivery_fee_total IS DISTINCT FROM 0::numeric) THEN RAISE EXCEPTION 'DIRECT_ORDER_RECIPIENT_PAYMENT_REQUIRED'; END IF;
 RETURN public.direct_order_quote_before_recipient($1,$2,$3,$4,mode);
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_quote_with_payment_mode(uuid,uuid,numeric,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_quote_with_payment_mode(uuid,uuid,numeric,text,text) TO authenticated,service_role;
CREATE OR REPLACE FUNCTION public.direct_order_staff_quote(p_store_id uuid,p_request_id uuid,p_delivery_fee_total numeric,p_cashier_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT public.direct_order_staff_quote_with_payment_mode($1,$2,$3,$4,NULL);
$$;

-- Preserve fee-free native pickup through the final-amount predecessor.
DO $native_pickup_quote$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.direct_order_quote_before_cash_default(uuid,uuid,numeric,text,text)'::regprocedure) INTO d;
 IF strpos(d,'p_delivery_payment_mode NOT IN (''customer_direct'',''store_prepaid'')')=0
 THEN RAISE EXCEPTION 'DIRECT_ORDER_NATIVE_PICKUP_QUOTE_PREDECESSOR_DRIFT'; END IF;
 d:=replace(d,'p_delivery_payment_mode NOT IN (''customer_direct'',''store_prepaid'')',
  'p_delivery_payment_mode NOT IN (''customer_direct'',''store_prepaid'',''not_applicable'')');
 d:=replace(d,'mode:=CASE WHEN r.fulfillment_method=''pickup'' THEN ''customer_direct''',
  'mode:=CASE WHEN r.fulfillment_type=''pickup'' THEN ''not_applicable'' WHEN r.fulfillment_method=''pickup'' THEN ''customer_direct''');
 d:=replace(d,'fee:=CASE WHEN r.fulfillment_method=''pickup'' OR r.delivery_fee_deferred THEN 0',
  'fee:=CASE WHEN r.fulfillment_type=''pickup'' OR r.fulfillment_method=''pickup'' OR r.delivery_fee_deferred THEN 0');
 EXECUTE d;
END; $native_pickup_quote$;

-- Defense in depth for predecessor RPCs and privileged table mutations.
CREATE FUNCTION public.direct_order_recipient_money_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
DECLARE v jsonb:=to_jsonb(NEW); policy integer;
BEGIN
 IF TG_TABLE_NAME='direct_order_financials' AND TG_OP='INSERT' THEN
  SELECT delivery_payment_mode INTO NEW.delivery_payment_mode FROM public.direct_order_quotes WHERE id=NEW.quote_id;
  v:=to_jsonb(NEW);
 END IF;
 SELECT delivery_policy_version INTO policy FROM public.direct_order_requests WHERE id=(v->>'request_id')::uuid AND fulfillment_type<>'pickup';
 IF policy IS DISTINCT FROM 2 THEN RETURN NEW; END IF;
 IF TG_TABLE_NAME IN ('direct_order_quotes','direct_order_financials') THEN
  IF v->>'delivery_payment_mode' IS DISTINCT FROM 'customer_direct' OR (v->>'delivery_fee_total')::numeric IS DISTINCT FROM 0::numeric
   THEN RAISE EXCEPTION 'DIRECT_ORDER_RECIPIENT_PAYMENT_REQUIRED'; END IF;
 ELSIF TG_TABLE_NAME='direct_order_payment_charges' THEN
  IF v->>'kind'='delivery' THEN RAISE EXCEPTION 'DIRECT_ORDER_RECIPIENT_PAYMENT_REQUIRED'; END IF;
 ELSIF TG_TABLE_NAME='direct_order_dispatches' THEN
  IF v->>'delivery_payment_mode' IS DISTINCT FROM 'customer_direct' OR v->>'actual_grab_fee' IS NOT NULL
   OR v->>'cash_paid_at' IS NOT NULL OR v->>'fee_variance' IS NOT NULL
   OR (v->>'customer_delivery_fee')::numeric IS DISTINCT FROM 0::numeric
   THEN RAISE EXCEPTION 'DIRECT_ORDER_RECIPIENT_PAYMENT_REQUIRED'; END IF;
  IF TG_OP='INSERT' AND current_setting('globos.recipient_handoff',true) IS DISTINCT FROM NEW.request_id::text
   THEN RAISE EXCEPTION 'DIRECT_ORDER_BOOKING_REQUIRED'; END IF;
 ELSE RAISE EXCEPTION 'DIRECT_ORDER_RECIPIENT_PAYMENT_REQUIRED'; END IF;
 RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_recipient_money_guard() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER direct_order_recipient_quotes BEFORE INSERT OR UPDATE ON public.direct_order_quotes FOR EACH ROW EXECUTE FUNCTION public.direct_order_recipient_money_guard();
CREATE TRIGGER direct_order_recipient_financials BEFORE INSERT OR UPDATE ON public.direct_order_financials FOR EACH ROW EXECUTE FUNCTION public.direct_order_recipient_money_guard();
CREATE TRIGGER direct_order_recipient_charges BEFORE INSERT OR UPDATE ON public.direct_order_payment_charges FOR EACH ROW EXECUTE FUNCTION public.direct_order_recipient_money_guard();
CREATE TRIGGER direct_order_recipient_dispatch BEFORE INSERT OR UPDATE ON public.direct_order_dispatches FOR EACH ROW EXECUTE FUNCTION public.direct_order_recipient_money_guard();
CREATE TRIGGER direct_order_recipient_cost BEFORE INSERT ON public.direct_order_delivery_cost_changes FOR EACH ROW EXECUTE FUNCTION public.direct_order_recipient_money_guard();
CREATE TRIGGER direct_order_recipient_cash BEFORE INSERT ON public.direct_order_driver_cash_movements FOR EACH ROW EXECUTE FUNCTION public.direct_order_recipient_money_guard();

ALTER FUNCTION public.direct_order_staff_support_action(uuid,uuid,integer,text,jsonb) RENAME TO direct_order_support_before_recipient;
REVOKE ALL ON FUNCTION public.direct_order_support_before_recipient(uuid,uuid,integer,text,jsonb) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_staff_support_action(p_store_id uuid,p_request_id uuid,p_expected_version integer,p_action text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE policy integer;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT delivery_policy_version INTO policy FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF policy=2 AND (p_action='defer_delivery_fee' OR p_action='charge' AND p_payload->>'kind'='delivery'
  OR p_action IN ('verify_delivery_cost','reconcile_delivery_fee','refund_delivery_complete','refund_delivery_adjustment','refund_original_pickup'))
 THEN RAISE EXCEPTION 'DIRECT_ORDER_RECIPIENT_PAYMENT_REQUIRED'; END IF;
 RETURN public.direct_order_support_before_recipient($1,$2,$3,$4,$5);
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_support_action(uuid,uuid,integer,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_support_action(uuid,uuid,integer,text,jsonb) TO authenticated,service_role;

-- A paper ticket has an explicit cooking milestone; KDS uses active quantities.
CREATE OR REPLACE FUNCTION public.direct_order_cooking_progress(p_request_ids uuid[])
RETURNS TABLE(request_id uuid,cooking_complete boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH scope AS MATERIALIZED(SELECT f.request_id,f.order_id,t.cooking_completed_at
  FROM public.direct_order_financials f LEFT JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id=f.request_id
  WHERE f.request_id=ANY(p_request_ids)), units AS(
  SELECT f.request_id,i.kitchen_done_quantity>=greatest(0,i.ordered_quantity-COALESCE(i.excused_quantity,0)) AND NOT i.needs_review AS done
  FROM scope f JOIN public.emergency_fulfillment_items i ON i.order_id=f.order_id WHERE NOT i.is_cancelled
  UNION ALL
  SELECT f.request_id,i.kitchen_done_quantity>=greatest(0,i.ordered_quantity-COALESCE(i.excused_quantity,0)) AND NOT i.needs_review
  FROM scope f JOIN public.emergency_combo_component_items i ON i.order_id=f.order_id WHERE NOT i.is_cancelled
 ), aggregate AS(SELECT request_id,bool_and(done) AS done FROM units GROUP BY request_id)
 SELECT s.request_id,CASE WHEN a.request_id IS NOT NULL THEN a.done ELSE s.cooking_completed_at IS NOT NULL END
 FROM scope s LEFT JOIN aggregate a ON a.request_id=s.request_id;
$$;
CREATE FUNCTION public.direct_order_mark_cooked(p_store_id uuid,p_ticket_id uuid,p_expected_version integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE t public.direct_delivery_fulfillment_tickets%ROWTYPE;o uuid;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['kitchen','cashier','admin','store_admin','brand_admin','super_admin']);
 PERFORM 1 FROM public.direct_order_requests r JOIN public.direct_delivery_fulfillment_tickets x ON x.request_id=r.id
  WHERE x.id=$2 AND r.restaurant_id=$1 AND r.state='approved' FOR UPDATE OF r;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_NOT_APPROVED'; END IF;
 SELECT * INTO t FROM public.direct_delivery_fulfillment_tickets WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF t.cooking_completed_at IS NOT NULL THEN RETURN to_jsonb(t)-ARRAY['restaurant_id','updated_by']; END IF;
 IF t.version IS DISTINCT FROM $3 OR t.status NOT IN ('preparing','ready') THEN RAISE EXCEPTION 'DIRECT_DELIVERY_TICKET_VERSION_CONFLICT'; END IF;
 SELECT order_id INTO o FROM public.direct_order_financials WHERE request_id=t.request_id;
 IF EXISTS(SELECT 1 FROM public.emergency_fulfillment_items WHERE order_id=o AND NOT is_cancelled)
 OR EXISTS(SELECT 1 FROM public.emergency_combo_component_items WHERE order_id=o AND NOT is_cancelled)
 THEN RAISE EXCEPTION 'DIRECT_ORDER_COOKING_USE_KDS'; END IF;
 UPDATE public.direct_delivery_fulfillment_tickets SET cooking_completed_at=now(),version=version+1,updated_at=now(),updated_by=auth.uid()
 WHERE id=t.id RETURNING * INTO t;
 PERFORM public.direct_order_progress_notice_batch(ARRAY[t.request_id],'cooking_complete');
 RETURN to_jsonb(t)-ARRAY['restaurant_id','updated_by'];
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_mark_cooked(uuid,uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_mark_cooked(uuid,uuid,integer) TO authenticated,service_role;

CREATE TABLE public.direct_order_delivery_bookings(
 id uuid PRIMARY KEY,request_id uuid NOT NULL REFERENCES public.direct_order_requests(id),
 restaurant_id uuid NOT NULL REFERENCES public.restaurants(id),
 status text NOT NULL CHECK(status IN ('booked','failed','cancelled','superseded','handed_off')),
 action text NOT NULL CHECK(action IN ('book','fail','cancel')),
 provider text CHECK(provider IN ('grab','be','other')),provider_name text,booking_reference text,
 driver_contact text,tracking_url text,recipient_fee numeric(15,2) CHECK(recipient_fee>=0 AND recipient_fee=trunc(recipient_fee)),
 reason text,mutation_payload jsonb NOT NULL,created_by uuid NOT NULL REFERENCES auth.users(id),
 created_at timestamptz NOT NULL DEFAULT clock_timestamp(),ended_at timestamptz,result jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE UNIQUE INDEX direct_order_one_active_booking ON public.direct_order_delivery_bookings(request_id) WHERE status='booked';
CREATE INDEX direct_order_booking_request_time ON public.direct_order_delivery_bookings(request_id,created_at DESC,id DESC);
ALTER TABLE public.direct_order_delivery_bookings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.direct_order_delivery_bookings FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.direct_order_delivery_bookings TO service_role;

CREATE FUNCTION public.direct_order_booking_snapshot(p_request_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT COALESCE((SELECT jsonb_build_object('id',id,'status',status,'provider',provider,'provider_name',provider_name,
 'reference',booking_reference,'driver_contact',driver_contact,'tracking_url',tracking_url,'recipient_fee',recipient_fee,
 'reason',reason,'created_at',created_at,'ended_at',ended_at) FROM public.direct_order_delivery_bookings
 WHERE request_id=$1 ORDER BY created_at DESC,id DESC LIMIT 1),'{}'::jsonb);
$$;
REVOKE ALL ON FUNCTION public.direct_order_booking_snapshot(uuid) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.direct_order_booking_action(p_store_id uuid,p_request_id uuid,p_expected_version integer,p_operation_id uuid,p_action text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE r public.direct_order_requests%ROWTYPE;t public.direct_delivery_fulfillment_tickets%ROWTYPE;
 previous public.direct_order_delivery_bookings%ROWTYPE;fee numeric;v jsonb;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF $4 IS NULL OR $5 IS NULL OR $5 NOT IN ('book','fail','cancel') OR $6 IS NULL OR jsonb_typeof($6)<>'object'
 THEN RAISE EXCEPTION 'DIRECT_ORDER_BOOKING_INPUT_INVALID'; END IF;
 SELECT * INTO previous FROM public.direct_order_delivery_bookings WHERE id=$4;
 IF FOUND THEN
  IF previous.request_id<>$2 OR previous.action<>$5 OR previous.mutation_payload IS DISTINCT FROM $6
  THEN RAISE EXCEPTION 'DIRECT_ORDER_BOOKING_CHANGED'; END IF;
  RETURN previous.result;
 END IF;
 SELECT * INTO t FROM public.direct_delivery_fulfillment_tickets WHERE request_id=$2 FOR UPDATE;
 IF r.delivery_policy_version<>2 OR r.state<>'approved' OR r.fulfillment_method<>'delivery' OR r.fulfillment_type<>'delivery' OR t.id IS NULL
  OR t.status NOT IN ('pending','preparing','ready') OR t.version IS DISTINCT FROM $3
  OR EXISTS(SELECT 1 FROM public.direct_order_pickup_offers WHERE request_id=$2 AND status='proposed')
 THEN RAISE EXCEPTION 'DIRECT_ORDER_BOOKING_CHANGED'; END IF;
 IF $5='book' THEN
  IF NOT COALESCE((SELECT cooking_complete FROM public.direct_order_cooking_progress(ARRAY[$2])),false)
   THEN RAISE EXCEPTION 'DIRECT_ORDER_COOKING_NOT_COMPLETE'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_object_keys($6) k WHERE k NOT IN ('provider','provider_name','reference','driver_contact','tracking_url','recipient_fee'))
 OR EXISTS(SELECT 1 FROM jsonb_each($6) e WHERE e.key<>'recipient_fee' AND jsonb_typeof(e.value) NOT IN ('string','null'))
 OR ($6->'recipient_fee' IS NOT NULL AND jsonb_typeof($6->'recipient_fee') NOT IN ('number','null'))
 THEN RAISE EXCEPTION 'DIRECT_ORDER_BOOKING_INPUT_INVALID'; END IF;
 fee:=($6->>'recipient_fee')::numeric;
  IF $6->>'provider' IS NULL OR $6->>'provider' NOT IN ('grab','be','other')
   OR $6->>'provider'='other' AND NULLIF(btrim($6->>'provider_name'),'') IS NULL
   OR NOT public.direct_order_tracking_url_valid(NULLIF(btrim($6->>'tracking_url'),''))
   OR (NULLIF(btrim($6->>'tracking_url'),'') IS NULL AND NULLIF(btrim($6->>'driver_contact'),'') IS NULL)
   OR fee<0 OR fee>9999999999999 OR fee<>trunc(fee) OR fee::text IN ('NaN','Infinity','-Infinity')
   OR char_length(COALESCE($6->>'driver_contact',''))>200 OR char_length(COALESCE($6->>'provider_name',''))>100
   OR char_length(COALESCE($6->>'reference',''))>200 THEN RAISE EXCEPTION 'DIRECT_ORDER_BOOKING_INPUT_INVALID'; END IF;
 ELSE
  IF EXISTS(SELECT 1 FROM jsonb_object_keys($6) k WHERE k<>'reason') OR jsonb_typeof($6->'reason') IS DISTINCT FROM 'string'
   OR char_length(btrim(COALESCE($6->>'reason',''))) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'DIRECT_ORDER_BOOKING_INPUT_INVALID'; END IF;
 END IF;
 UPDATE public.direct_order_delivery_bookings SET status=CASE WHEN $5='book' THEN 'superseded' ELSE 'cancelled' END,ended_at=clock_timestamp()
 WHERE request_id=$2 AND status='booked';
 INSERT INTO public.direct_order_delivery_bookings(id,request_id,restaurant_id,status,action,provider,provider_name,
 booking_reference,driver_contact,tracking_url,recipient_fee,reason,mutation_payload,created_by)
 VALUES($4,$2,$1,CASE $5 WHEN 'book' THEN 'booked' WHEN 'fail' THEN 'failed' ELSE 'cancelled' END,$5,$6->>'provider',
 NULLIF(btrim($6->>'provider_name'),''),NULLIF(btrim($6->>'reference'),''),NULLIF(btrim($6->>'driver_contact'),''),
 NULLIF(btrim($6->>'tracking_url'),''),fee,NULLIF(btrim($6->>'reason'),''),$6,auth.uid());
 UPDATE public.direct_delivery_fulfillment_tickets SET version=version+1,updated_at=now() WHERE id=t.id;
 v:=public.direct_order_booking_snapshot($2);
 UPDATE public.direct_order_delivery_bookings SET result=v WHERE id=$4;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,metadata)
 VALUES($2,$1,'system','system',CASE $5 WHEN 'book' THEN 'DIRECT_ORDER_DRIVER_BOOKED' ELSE 'DIRECT_ORDER_BOOKING_RETRY' END,
 jsonb_build_object('booking_id',$4,'action',$5));
 RETURN v;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_booking_action(uuid,uuid,integer,uuid,text,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_booking_action(uuid,uuid,integer,uuid,text,jsonb) TO authenticated,service_role;

CREATE FUNCTION public.direct_order_handoff_booking(p_store_id uuid,p_request_id uuid,p_expected_version integer,p_booking_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE b public.direct_order_delivery_bookings%ROWTYPE;r public.direct_order_requests%ROWTYPE;v jsonb;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND OR r.delivery_policy_version<>2 OR r.state<>'approved' OR r.fulfillment_method<>'delivery' OR r.fulfillment_type<>'delivery'
  THEN RAISE EXCEPTION 'DIRECT_ORDER_BOOKING_CHANGED'; END IF;
 SELECT * INTO b FROM public.direct_order_delivery_bookings WHERE id=$4 AND request_id=$2 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_BOOKING_REQUIRED'; END IF;
 IF b.status='handed_off' AND EXISTS(SELECT 1 FROM public.direct_order_dispatches WHERE request_id=$2)
  THEN RETURN public.direct_order_fulfillment_context($2); END IF;
 IF b.status<>'booked' THEN RAISE EXCEPTION 'DIRECT_ORDER_BOOKING_CHANGED'; END IF;
 PERFORM set_config('globos.recipient_handoff',$2::text,true);
 v:=public.direct_order_set_dispatch_v4($1,$2,$3,b.provider,b.tracking_url,NULL,b.provider_name,b.driver_contact);
 PERFORM set_config('globos.recipient_handoff','',true);
 UPDATE public.direct_order_delivery_bookings SET status='handed_off',ended_at=clock_timestamp() WHERE id=b.id;
 RETURN v;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_handoff_booking(uuid,uuid,integer,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_handoff_booking(uuid,uuid,integer,uuid) TO authenticated,service_role;

-- A generic attachment never approves payment or changes a charge.
CREATE FUNCTION public.direct_order_commit_chat_attachment(p_request_id uuid,p_store_id uuid,p_sender text,p_actor uuid,
 p_path text,p_filename text,p_mime text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE r public.direct_order_requests%ROWTYPE;m public.direct_order_messages%ROWTYPE;
BEGIN
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$1 AND restaurant_id=$2 FOR UPDATE;
 IF NOT FOUND OR p_sender IS NULL OR p_sender NOT IN ('cashier','customer') OR p_path IS NULL
  OR p_path NOT LIKE $2::text||'/'||$1::text||'/%' OR char_length(COALESCE(p_filename,'')) NOT BETWEEN 1 AND 255
  OR p_mime IS NULL OR p_mime NOT IN ('image/jpeg','image/png','image/webp','application/pdf')
 THEN RAISE EXCEPTION 'DIRECT_ORDER_ATTACHMENT_INVALID'; END IF;
 SELECT * INTO m FROM public.direct_order_messages WHERE attachment_storage_path=$5;
 IF FOUND THEN
  IF m.request_id<>r.id OR m.sender_type<>$3 OR m.message_type<>'attachment'
   OR m.metadata->>'attachment_kind' IS DISTINCT FROM 'chat' OR m.metadata->>'mime_type' IS DISTINCT FROM $7
   OR m.body IS DISTINCT FROM $6 OR m.sender_auth_id IS DISTINCT FROM $4 THEN RAISE EXCEPTION 'DIRECT_ORDER_ATTACHMENT_INVALID'; END IF;
  RETURN jsonb_build_object('message_id',m.id,'created_at',m.created_at);
 END IF;
 IF r.support_closed_at IS NOT NULL OR r.pii_purged_at IS NOT NULL OR NOT public.direct_order_access_is_open(r.id)
 THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_CHATABLE'; END IF;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,sender_auth_id,message_type,body,attachment_storage_path,metadata)
 VALUES($1,$2,$3,$4,'attachment',$6,$5,jsonb_build_object('attachment_bucket','direct-order-chat','attachment_kind','chat',
 'filename',$6,'mime_type',$7)) RETURNING * INTO m;
 RETURN jsonb_build_object('message_id',m.id,'created_at',m.created_at);
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_commit_chat_attachment(uuid,uuid,text,uuid,text,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_commit_chat_attachment(uuid,uuid,text,uuid,text,text,text) TO service_role;

CREATE FUNCTION public.direct_order_orphan_chat_candidates(p_limit integer DEFAULT 100) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,storage,pg_catalog AS $$
BEGIN
 IF $1 IS NULL OR $1 NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'DIRECT_ORDER_CLEANUP_LIMIT_INVALID'; END IF;
 RETURN COALESCE((SELECT jsonb_agg(c.name ORDER BY c.created_at,c.id) FROM(
 SELECT o.id,o.name,o.created_at FROM storage.objects o LEFT JOIN public.direct_order_messages m
 ON m.attachment_storage_path=o.name WHERE o.bucket_id='direct-order-chat'
 AND o.created_at<now()-interval '1 day' AND m.id IS NULL ORDER BY o.created_at,o.id LIMIT $1) c),'[]'::jsonb);
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_orphan_chat_candidates(integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_orphan_chat_candidates(integer) TO service_role;

-- Versioned projections leave old strict customer DTOs unchanged.
CREATE FUNCTION public.direct_order_public_status_v10(p_session_id uuid,p_secret_hash text,p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE v jsonb;policy integer;
BEGIN
 v:=public.direct_order_public_status_v9($1,$2,$3);
 SELECT delivery_policy_version INTO policy FROM public.direct_order_requests WHERE id=$3;
 RETURN v||jsonb_build_object('delivery',v->'delivery'||jsonb_build_object('booking',public.direct_order_booking_snapshot($3)),
 'support',v->'support'||jsonb_build_object('delivery_policy_version',policy));
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_public_status_v10(uuid,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_status_v10(uuid,text,uuid) TO service_role;
CREATE FUNCTION public.direct_order_staff_detail_v6(p_store_id uuid,p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v jsonb;
BEGIN
 v:=public.direct_order_staff_detail_v5($1,$2);
 RETURN v||jsonb_build_object('booking',public.direct_order_booking_snapshot($2),
 'delivery',v->'delivery'||jsonb_build_object('cooking_complete',COALESCE((SELECT cooking_complete FROM public.direct_order_cooking_progress(ARRAY[$2])),false)));
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_staff_detail_v6(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_detail_v6(uuid,uuid) TO authenticated,service_role;
CREATE FUNCTION public.direct_order_staff_list_v5(p_store_id uuid,p_states text[] DEFAULT NULL,p_limit integer DEFAULT 100,p_fulfillment_type text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
 WITH page AS MATERIALIZED(SELECT e.value,e.ordinality FROM jsonb_array_elements(public.direct_order_staff_list_v4($1,$2,$3,$4)) WITH ORDINALITY e),
 scope AS MATERIALIZED(SELECT (value->>'id')::uuid AS id FROM page),
 cooking AS MATERIALIZED(SELECT * FROM public.direct_order_cooking_progress(ARRAY(SELECT id FROM scope))),
 bookings AS(SELECT DISTINCT ON(b.request_id) b.request_id,b.status FROM public.direct_order_delivery_bookings b
 JOIN scope s ON s.id=b.request_id ORDER BY b.request_id,b.created_at DESC,b.id DESC)
 SELECT COALESCE(jsonb_agg(p.value||jsonb_build_object('cooking_complete',COALESCE(c.cooking_complete,false),
 'booking_status',b.status) ORDER BY p.ordinality),'[]'::jsonb) FROM page p
 LEFT JOIN cooking c ON c.request_id::text=p.value->>'id' LEFT JOIN bookings b ON b.request_id::text=p.value->>'id';
$$;
REVOKE ALL ON FUNCTION public.direct_order_staff_list_v5(uuid,text[],integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_list_v5(uuid,text[],integer,text) TO authenticated,service_role;

CREATE FUNCTION public.direct_delivery_ticket_list_v4(p_store_id uuid,p_statuses text[] DEFAULT NULL,p_limit integer DEFAULT 200) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
 WITH page AS MATERIALIZED(SELECT e.value,e.ordinality FROM jsonb_array_elements(public.direct_delivery_ticket_list_v3($1,$2,$3)) WITH ORDINALITY e),
 scope AS MATERIALIZED(SELECT t.id,f.order_id,t.request_id,r.delivery_policy_version FROM page p
  JOIN public.direct_delivery_fulfillment_tickets t ON t.id=(p.value->>'id')::uuid JOIN public.direct_order_requests r ON r.id=t.request_id
 JOIN public.direct_order_financials f ON f.request_id=t.request_id),
 kds AS(SELECT i.order_id FROM public.emergency_fulfillment_items i JOIN scope s ON s.order_id=i.order_id WHERE NOT i.is_cancelled
 UNION SELECT i.order_id FROM public.emergency_combo_component_items i JOIN scope s ON s.order_id=i.order_id WHERE NOT i.is_cancelled),
 cooking AS MATERIALIZED(SELECT * FROM public.direct_order_cooking_progress(ARRAY(SELECT request_id FROM scope)))
 SELECT COALESCE(jsonb_agg(p.value||jsonb_build_object('delivery_policy_version',s.delivery_policy_version,
 'manual_cooking_available',k.order_id IS NULL,'cooking_complete',COALESCE(c.cooking_complete,false)) ORDER BY p.ordinality),'[]'::jsonb)
 FROM page p JOIN scope s ON s.id=(p.value->>'id')::uuid LEFT JOIN kds k ON k.order_id=s.order_id LEFT JOIN cooking c ON c.request_id=s.request_id;
$$;
REVOKE ALL ON FUNCTION public.direct_delivery_ticket_list_v4(uuid,text[],integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_delivery_ticket_list_v4(uuid,text[],integer) TO authenticated,service_role;

CREATE FUNCTION public.direct_order_recipient_ready_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
BEGIN
 IF NEW.status='ready' AND OLD.status IS DISTINCT FROM 'ready'
  AND EXISTS(SELECT 1 FROM public.direct_order_requests WHERE id=NEW.request_id AND delivery_policy_version=2)
  AND NOT COALESCE((SELECT cooking_complete FROM public.direct_order_cooking_progress(ARRAY[NEW.request_id])),false)
 THEN RAISE EXCEPTION 'DIRECT_ORDER_COOKING_NOT_COMPLETE'; END IF;
 RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_recipient_ready_guard() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER direct_order_recipient_ready BEFORE UPDATE OF status ON public.direct_delivery_fulfillment_tickets
 FOR EACH ROW EXECUTE FUNCTION public.direct_order_recipient_ready_guard();

-- Ticket transitions acquire request before ticket, matching booking/pickup/
-- cancellation and the completion notice's request foreign-key lock.
ALTER FUNCTION public.direct_delivery_ticket_transition(uuid,uuid,integer,text) RENAME TO direct_delivery_transition_before_recipient;
REVOKE ALL ON FUNCTION public.direct_delivery_transition_before_recipient(uuid,uuid,integer,text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_delivery_ticket_transition(p_store_id uuid,p_ticket_id uuid,p_expected_version integer,p_next_status text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
 PERFORM public.direct_order_require_actor($1,CASE WHEN $4='completed' THEN ARRAY['cashier','admin','store_admin','brand_admin','super_admin']
 ELSE ARRAY['kitchen','cashier','admin','store_admin','brand_admin','super_admin'] END);
 PERFORM 1 FROM public.direct_order_requests r JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id=r.id
 WHERE t.id=$2 AND t.restaurant_id=$1 FOR UPDATE OF r;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_DELIVERY_TICKET_NOT_FOUND'; END IF;
 RETURN public.direct_delivery_transition_before_recipient($1,$2,$3,$4);
END; $$;
REVOKE ALL ON FUNCTION public.direct_delivery_ticket_transition(uuid,uuid,integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_delivery_ticket_transition(uuid,uuid,integer,text) TO authenticated,service_role;

-- Preserve the single batch completion aggregate and capture its actual event time.
ALTER FUNCTION public.direct_order_progress_notice_batch(uuid[],text) RENAME TO direct_order_progress_notice_before_recipient;
REVOKE ALL ON FUNCTION public.direct_order_progress_notice_before_recipient(uuid[],text) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_progress_notice_batch(p_ids uuid[],p_kind text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 PERFORM public.direct_order_progress_notice_before_recipient($1,$2);
 IF $2='cooking_complete' THEN
  UPDATE public.direct_delivery_fulfillment_tickets t SET cooking_completed_at=e.created_at
  FROM public.direct_order_customer_events e WHERE e.request_id=t.request_id AND t.request_id=ANY($1)
   AND e.event_kind='cooking_complete' AND t.cooking_completed_at IS NULL;
 END IF;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_progress_notice_batch(uuid[],text) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.direct_order_booking_cancel_terminal() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 UPDATE public.direct_order_delivery_bookings SET status='cancelled',ended_at=clock_timestamp()
 WHERE request_id=NEW.id AND status='booked';
 RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_booking_cancel_terminal() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER direct_order_booking_cancel_terminal AFTER UPDATE OF state,fulfillment_method ON public.direct_order_requests
 FOR EACH ROW WHEN(NEW.fulfillment_method='pickup' OR NEW.state IN ('cancelled','rejected','expired'))
 EXECUTE FUNCTION public.direct_order_booking_cancel_terminal();

CREATE FUNCTION public.direct_order_booking_purge_pii() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 UPDATE public.direct_order_delivery_bookings SET booking_reference=NULL,driver_contact=NULL,tracking_url=NULL,reason=NULL,
 mutation_payload='{}'::jsonb,result='{}'::jsonb WHERE request_id=NEW.id;
 RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_booking_purge_pii() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER direct_order_booking_purge_pii AFTER UPDATE OF pii_purged_at ON public.direct_order_requests
 FOR EACH ROW WHEN(NEW.pii_purged_at IS NOT NULL AND OLD.pii_purged_at IS NULL)
 EXECUTE FUNCTION public.direct_order_booking_purge_pii();
UPDATE public.direct_delivery_fulfillment_tickets t SET cooking_completed_at=e.created_at
FROM public.direct_order_customer_events e WHERE e.request_id=t.request_id AND e.event_kind='cooking_complete';

-- Versioned customer page: one booking aggregate for the whole page.
CREATE FUNCTION public.direct_order_public_orders_v5(p_session_id uuid,p_secret_hash text,p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE v jsonb;
BEGIN
 v:=public.direct_order_public_orders_v4($1,$2,$3);
 RETURN (WITH page AS MATERIALIZED(SELECT value,ordinality FROM jsonb_array_elements(v) WITH ORDINALITY),
 bookings AS(SELECT DISTINCT ON(b.request_id) b.request_id,b.status FROM public.direct_order_delivery_bookings b
 JOIN page p ON b.request_id::text=p.value->>'request_id' ORDER BY b.request_id,b.created_at DESC,b.id DESC)
 SELECT COALESCE(jsonb_agg(p.value||jsonb_build_object('booking_status',b.status) ORDER BY p.ordinality),'[]'::jsonb)
 FROM page p LEFT JOIN bookings b ON b.request_id::text=p.value->>'request_id');
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_public_orders_v5(uuid,text,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_orders_v5(uuid,text,integer) TO service_role;

CREATE FUNCTION public.direct_order_analytics_v4(p_store_id uuid,p_from_date date,p_to_date date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE v jsonb;metrics jsonb;
BEGIN
 v:=public.direct_order_analytics_v3($1,$2,$3);
 WITH scope AS MATERIALIZED(SELECT r.id,r.delivery_policy_version,t.status,t.cooking_completed_at,d.sent_at
 FROM public.direct_order_requests r JOIN public.direct_order_financials f ON f.request_id=r.id
 LEFT JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id=r.id
 LEFT JOIN public.direct_order_dispatches d ON d.request_id=r.id
 WHERE r.restaurant_id=$1 AND (f.approved_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date BETWEEN $2 AND $3),
 events AS(SELECT b.request_id,min(b.created_at) FILTER(WHERE b.action='book') first_booked,
 count(*) FILTER(WHERE b.action='book') bookings,count(*) FILTER(WHERE b.action='fail') failures,
 bool_or(b.status='booked') active FROM public.direct_order_delivery_bookings b JOIN scope s ON s.id=b.request_id GROUP BY b.request_id)
 SELECT jsonb_build_object('legacy_delivery_order_count',count(*) FILTER(WHERE s.delivery_policy_version=1),
 'booking_failures',COALESCE(sum(e.failures),0),'booking_retries',COALESCE(sum(greatest(e.bookings-1,0)),0),
 'awaiting_booking',count(*) FILTER(WHERE s.delivery_policy_version=2 AND s.cooking_completed_at IS NOT NULL
 AND s.status IN ('pending','preparing','ready') AND NOT COALESCE(e.active,false)),
 'cooking_to_booking_minutes',avg(extract(epoch FROM(e.first_booked-s.cooking_completed_at))/60)
 FILTER(WHERE e.first_booked>=s.cooking_completed_at),
 'cooking_to_handoff_minutes',avg(extract(epoch FROM(s.sent_at-s.cooking_completed_at))/60)
 FILTER(WHERE s.sent_at>=s.cooking_completed_at)) INTO metrics
 FROM scope s LEFT JOIN events e ON e.request_id=s.id;
 RETURN jsonb_set(v,'{summary}',v->'summary'||metrics);
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_analytics_v4(uuid,date,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_analytics_v4(uuid,date,date) TO authenticated,service_role;

DO $verify$
BEGIN
 IF has_table_privilege('authenticated','public.direct_order_delivery_bookings','SELECT')
 OR has_function_privilege('anon','public.direct_order_booking_action(uuid,uuid,integer,uuid,text,jsonb)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_commit_chat_attachment(uuid,uuid,text,uuid,text,text,text)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_quote_before_recipient(uuid,uuid,numeric,text,text)','EXECUTE')
 OR NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='direct_order_recipient_dispatch' AND tgenabled='O')
 THEN RAISE EXCEPTION 'DIRECT_ORDER_RECIPIENT_PERMISSION_DRIFT'; END IF;
END; $verify$;

-- COMPONENT 20261010051000_direct_order_recipient_receipts.sql SHA256 f86410e917ef7cbb1c461de4931e4502f6e7dfaa947b6ec3708867847b3d2eda
-- Carry the payer in immutable print/digital snapshots and isolate old agents.
-- production-gate: self-verifying

SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
CREATE FUNCTION public.direct_order_enrich_recipient_print() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE context jsonb;
BEGIN
 SELECT jsonb_build_object('delivery_payment_mode',f.delivery_payment_mode,
 'delivery_policy_version',r.delivery_policy_version,'receipt_payload_version',2)
 INTO context FROM public.direct_order_financials f JOIN public.direct_order_requests r ON r.id=f.request_id
 WHERE f.order_id=NEW.order_id AND f.restaurant_id=NEW.restaurant_id;
 IF context IS NOT NULL THEN NEW.payload:=NEW.payload||context; END IF;
 RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_enrich_recipient_print() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zzzzzz_direct_order_recipient_print BEFORE INSERT ON public.print_jobs
 FOR EACH ROW EXECUTE FUNCTION public.direct_order_enrich_recipient_print();
CREATE FUNCTION public.direct_order_enrich_recipient_digital() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE context jsonb;
BEGIN
 IF NEW.combined_payment_group_id IS NOT NULL THEN RETURN NEW; END IF;
 SELECT jsonb_build_object('delivery_payment_mode',f.delivery_payment_mode,'delivery_policy_version',r.delivery_policy_version)
 INTO context FROM public.direct_order_financials f JOIN public.direct_order_requests r ON r.id=f.request_id
 WHERE f.order_id=NEW.order_id AND f.restaurant_id=NEW.restaurant_id;
 IF context IS NOT NULL THEN NEW.snapshot:=NEW.snapshot||context; END IF;
 RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_enrich_recipient_digital() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zzzzzz_direct_order_recipient_digital BEFORE INSERT ON public.digital_receipts
 FOR EACH ROW EXECUTE FUNCTION public.direct_order_enrich_recipient_digital();

ALTER FUNCTION public.direct_order_receipt_packing_context(uuid,uuid) RENAME TO direct_order_packing_before_recipient;
REVOKE ALL ON FUNCTION public.direct_order_packing_before_recipient(uuid,uuid) FROM PUBLIC,anon,authenticated;
CREATE FUNCTION public.direct_order_receipt_packing_context(p_store_id uuid,p_order_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v jsonb;context jsonb;
BEGIN
 v:=public.direct_order_packing_before_recipient($1,$2);
 SELECT jsonb_build_object('delivery_payment_mode',f.delivery_payment_mode,'delivery_policy_version',r.delivery_policy_version)
 INTO context FROM public.direct_order_financials f JOIN public.direct_order_requests r ON r.id=f.request_id
 WHERE f.order_id=$2 AND f.restaurant_id=$1;
 RETURN CASE WHEN context IS NULL THEN v ELSE v||context END;
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_receipt_packing_context(uuid,uuid) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_receipt_packing_context(uuid,uuid) TO authenticated,service_role;

-- Upgrade only unsent jobs against their financial source. Issued snapshots stay immutable.
UPDATE public.print_jobs j SET payload=j.payload||jsonb_build_object(
 'delivery_payment_mode',f.delivery_payment_mode,'delivery_policy_version',r.delivery_policy_version,'receipt_payload_version',2)
FROM public.direct_order_financials f JOIN public.direct_order_requests r ON r.id=f.request_id
WHERE j.order_id=f.order_id AND j.restaurant_id=f.restaurant_id AND j.status IN ('pending','failed');

-- Preserve the effective main routing/retry/memo/utensil contracts. v3 adds
-- recipient wording; older agents keep their existing exclusions and cannot
-- claim a payload they cannot render.
DO $claim_capability$
DECLARE original text; upgraded text;
BEGIN
 SELECT pg_get_functiondef('public.claim_print_jobs(uuid,integer)'::regprocedure) INTO original;
 SELECT pg_get_functiondef('public.claim_print_jobs_v2(uuid,integer)'::regprocedure) INTO upgraded;
 IF strpos(original,'AND emergency_held_at IS NULL')=0
 OR strpos(upgraded,'AND emergency_held_at IS NULL')=0
 OR strpos(original,'request_update')=0 OR strpos(original,'utensils_requested')=0
 THEN RAISE EXCEPTION 'DIRECT_ORDER_RECIPIENT_RECEIPT_DRIFT'; END IF;
 EXECUTE replace(replace(upgraded,'public.claim_print_jobs_v2(', 'public.claim_print_jobs_v3('),
  'AND emergency_held_at IS NULL',
  'AND emergency_held_at IS NULL AND COALESCE((payload->>''receipt_payload_version'')::integer,1)<=2');
 EXECUTE replace(upgraded,'AND emergency_held_at IS NULL',
  'AND emergency_held_at IS NULL AND COALESCE((payload->>''receipt_payload_version'')::integer,1)<2');
 EXECUTE replace(original,'AND emergency_held_at IS NULL',
  'AND emergency_held_at IS NULL AND COALESCE((payload->>''receipt_payload_version'')::integer,1)<2');
END; $claim_capability$;
REVOKE ALL ON FUNCTION public.claim_print_jobs_v3(uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.claim_print_jobs_v3(uuid,integer) TO authenticated,service_role;

DO $verify$
BEGIN
 IF has_function_privilege('anon','public.claim_print_jobs_v3(uuid,integer)','EXECUTE')
 OR NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='zzzzzz_direct_order_recipient_print' AND tgenabled='O')
 OR NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgname='zzzzzz_direct_order_recipient_digital' AND tgenabled='O')
 THEN RAISE EXCEPTION 'DIRECT_ORDER_RECIPIENT_RECEIPT_DRIFT'; END IF;
END; $verify$;

-- COMPONENT 20261010052000_direct_order_batch_refund_invoice.sql SHA256 12d06a3f8f3e50b5452b04f14dcf75caaf265a6c33d66157a7fe61b874507277
-- All direct-order payment targets are locked/aggregated as one set. No change
-- to process_payment or the asynchronous MISA issuance queue.
-- production-gate: self-verifying

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

-- COMPONENT 20261010053000_pos_buyer_information.sql SHA256 b7e27135274b0ec44f245c0732608432bf3b3066ea78a0250a420a9e76213e64
-- POS buyer information only. No MISA dispatch, issuance or payment changes.
-- production-gate: self-verifying

SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';

ALTER TABLE public.red_invoice_intakes
 ADD COLUMN buyer_number_type text NOT NULL DEFAULT 'vn_tax' CHECK(buyer_number_type IN ('vn_tax','household_id','personal_id','foreign_tax','passport')),
 ADD COLUMN buyer_number_value text NOT NULL DEFAULT '',
 ADD COLUMN buyer_version bigint NOT NULL DEFAULT 1;
-- Keep legacy invalid numbers verbatim. Display their error; do not repair them.
UPDATE public.red_invoice_intakes SET buyer_number_type=CASE WHEN COALESCE(buyer_tax_code,'')='' AND COALESCE(buyer_id,'')<>'' THEN 'personal_id' ELSE 'vn_tax' END,
 buyer_number_value=COALESCE(NULLIF(buyer_tax_code,''),buyer_id,'');

CREATE FUNCTION public.pos_buyer_number_issue(p_type text,p_value text) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path=pg_catalog AS $$
DECLARE v text:=btrim(COALESCE($2,''));parts text[];
BEGIN
 IF $1 IS NULL OR $1 NOT IN ('vn_tax','household_id','personal_id','foreign_tax','passport') THEN RETURN jsonb_build_object('code','type'); END IF;
 IF v='' THEN RETURN jsonb_build_object('code','required'); END IF;
 IF $1 IN ('foreign_tax','passport') THEN RETURN CASE WHEN char_length(v)>64 THEN jsonb_build_object('code','too_long') ELSE NULL END; END IF;
 IF $1<>'vn_tax' THEN
  IF v!~'^[0-9]+$' THEN RETURN jsonb_build_object('code','digits'); END IF;
  RETURN CASE WHEN char_length(v)=12 THEN NULL ELSE jsonb_build_object('code','identity_length','actual',char_length(v)) END;
 END IF;
 IF v!~'^[0-9-]+$' THEN RETURN jsonb_build_object('code','tax_characters'); END IF;
 IF strpos(v,'-')>0 THEN
  parts:=string_to_array(v,'-');
  IF cardinality(parts)<>2 THEN RETURN jsonb_build_object('code','hyphen'); END IF;
  IF char_length(parts[1])<>10 OR char_length(parts[2])<>3 THEN RETURN jsonb_build_object('code','branch_length','left',char_length(parts[1]),'right',char_length(parts[2])); END IF;
  RETURN CASE WHEN parts[2]='000' THEN jsonb_build_object('code','branch_zero') ELSE NULL END;
 END IF;
 RETURN CASE WHEN char_length(v)=10 THEN NULL ELSE jsonb_build_object('code','tax_length','actual',char_length(v)) END;
END; $$;
REVOKE ALL ON FUNCTION public.pos_buyer_number_issue(text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pos_buyer_number_issue(text,text) TO authenticated,service_role;

CREATE FUNCTION public.pos_buyer_intake_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
DECLARE issue jsonb;explicit_edit boolean:=current_setting('globos.pos_buyer_explicit',true)='true';changed boolean;
BEGIN
 IF TG_OP='UPDATE' THEN
  -- Legacy minimal/batch writers omitted these fields by passing NULL.
  -- An explicit POS patch can still clear a field intentionally.
  IF NOT COALESCE(explicit_edit,false) THEN
   NEW.buyer_unit_code:=COALESCE(NEW.buyer_unit_code,OLD.buyer_unit_code);
   NEW.buyer_full_name:=COALESCE(NEW.buyer_full_name,OLD.buyer_full_name);
   NEW.buyer_email_cc:=COALESCE(NEW.buyer_email_cc,OLD.buyer_email_cc);
   NEW.buyer_id:=COALESCE(NEW.buyer_id,OLD.buyer_id);
   IF NEW.buyer_number_value=OLD.buyer_number_value AND
    ROW(NEW.buyer_tax_code,NEW.buyer_id) IS DISTINCT FROM ROW(OLD.buyer_tax_code,OLD.buyer_id) THEN
    NEW.buyer_number_value:=COALESCE(CASE WHEN NEW.buyer_number_type IN ('personal_id','passport') THEN NEW.buyer_id ELSE NEW.buyer_tax_code END,'');
   END IF;
  END IF;
 ELSE
  IF NEW.buyer_number_value='' THEN NEW.buyer_number_value:=COALESCE(CASE WHEN NEW.buyer_number_type IN ('personal_id','passport') THEN NEW.buyer_id ELSE NEW.buyer_tax_code END,''); END IF;
 END IF;
 changed:=TG_OP='INSERT';
 IF TG_OP='UPDATE' THEN
  changed:=ROW(NEW.buyer_number_type,NEW.buyer_number_value,NEW.buyer_tax_code,NEW.buyer_unit_code,NEW.buyer_legal_name,NEW.buyer_full_name,
   NEW.buyer_address,NEW.buyer_email,NEW.buyer_email_cc,NEW.buyer_phone,NEW.buyer_id,NEW.source_note,NEW.attachment_urls)
  IS DISTINCT FROM ROW(OLD.buyer_number_type,OLD.buyer_number_value,OLD.buyer_tax_code,OLD.buyer_unit_code,OLD.buyer_legal_name,OLD.buyer_full_name,
   OLD.buyer_address,OLD.buyer_email,OLD.buyer_email_cc,OLD.buyer_phone,OLD.buyer_id,OLD.source_note,OLD.attachment_urls);
  IF changed THEN NEW.buyer_version:=OLD.buyer_version+1; END IF;
 END IF;
 IF NEW.status IN ('ready','exported','completed') AND (TG_OP='INSERT' OR TG_OP='UPDATE' AND (OLD.status='awaiting_information' OR ROW(NEW.buyer_number_type,NEW.buyer_number_value,NEW.buyer_tax_code,NEW.buyer_id,NEW.buyer_legal_name,NEW.buyer_full_name,NEW.buyer_address,NEW.buyer_email,NEW.buyer_phone) IS DISTINCT FROM ROW(OLD.buyer_number_type,OLD.buyer_number_value,OLD.buyer_tax_code,OLD.buyer_id,OLD.buyer_legal_name,OLD.buyer_full_name,OLD.buyer_address,OLD.buyer_email,OLD.buyer_phone))) THEN
  issue:=public.pos_buyer_number_issue(NEW.buyer_number_type,NEW.buyer_number_value);
  IF issue IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_NUMBER_INVALID' USING DETAIL=issue::text; END IF;
 END IF;
 RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.pos_buyer_intake_guard() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER pos_buyer_intake_guard BEFORE INSERT OR UPDATE ON public.red_invoice_intakes
 FOR EACH ROW EXECUTE FUNCTION public.pos_buyer_intake_guard();

CREATE FUNCTION public.pos_save_buyer_information(p_store_id uuid,p_order_id uuid,p_expected_version bigint,p_patch jsonb,p_confirm boolean DEFAULT true,p_source text DEFAULT NULL,p_intake_status text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE actor public.users%ROWTYPE;existing public.red_invoice_intakes%ROWTYPE;v public.red_invoice_intakes%ROWTYPE;
 v_request_id uuid;data jsonb;issue jsonb;kind text;number text;target_ids uuid[];prior_setting text;
BEGIN
 SELECT * INTO actor FROM public.users WHERE auth_id=auth.uid() AND is_active LIMIT 1;
 IF NOT FOUND OR actor.role NOT IN ('cashier','admin','store_admin','brand_admin','super_admin') THEN RAISE EXCEPTION 'RED_INVOICE_INTAKE_FORBIDDEN'; END IF;
 IF NOT public.is_super_admin() AND NOT EXISTS(SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(store_id) WHERE s.store_id=$1) THEN RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN'; END IF;
 IF $6 IS NOT NULL AND $6 NOT IN ('cashier','business_card','zalo','other') OR $7 IS NOT NULL AND $7 NOT IN ('awaiting_information','ready','manual_review','cancelled') THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 IF $4 IS NULL OR jsonb_typeof($4)<>'object' OR EXISTS(SELECT 1 FROM jsonb_each($4) e WHERE e.key NOT IN
 ('buyer_number_type','buyer_number_value','buyer_legal_name','buyer_full_name','buyer_address','buyer_email','buyer_email_cc','buyer_phone','buyer_unit_code','buyer_id','source_note')
 OR jsonb_typeof(e.value)<>'string') THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 -- Request first, then its intake rows: same lock order as direct-order sync.
 SELECT f.request_id INTO v_request_id FROM public.direct_order_financials f WHERE f.order_id=$2 AND f.restaurant_id=$1;
 IF v_request_id IS NULL THEN SELECT c.request_id INTO v_request_id FROM public.direct_order_payment_charges c WHERE c.order_id=$2 AND c.restaurant_id=$1; END IF;
 IF v_request_id IS NOT NULL THEN PERFORM 1 FROM public.direct_order_requests WHERE id=v_request_id FOR UPDATE; END IF;
 PERFORM 1 FROM public.orders WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
 SELECT * INTO existing FROM public.red_invoice_intakes WHERE order_id=$2 AND store_id=$1 FOR UPDATE;
 IF FOUND AND existing.buyer_version IS DISTINCT FROM $3 OR NOT FOUND AND $3 IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_CHANGED'; END IF;
 IF EXISTS(SELECT 1 FROM public.restaurants WHERE id=$1 AND brand_id='77000000-0000-0000-0000-000000000001') THEN RAISE EXCEPTION 'RED_INVOICE_DISABLED_FOR_PHOTO_OBJET'; END IF;
 data:=COALESCE(to_jsonb(existing),'{}'::jsonb)||$4;
 kind:=COALESCE(data->>'buyer_number_type','vn_tax');number:=COALESCE(data->>'buyer_number_value','');
 IF kind NOT IN ('vn_tax','household_id','personal_id','foreign_tax','passport') THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 IF $5 OR $7='ready' OR existing.status IN ('ready','exported','completed') THEN
  issue:=public.pos_buyer_number_issue(kind,number);
  IF issue IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_NUMBER_INVALID' USING DETAIL=issue::text; END IF;
  IF COALESCE(btrim(data->>'buyer_address'),'')='' OR COALESCE(btrim(data->>'buyer_phone'),'')='' OR COALESCE(data->>'buyer_email','') NOT LIKE '%@%'
  OR COALESCE(btrim(CASE WHEN kind IN ('personal_id','passport') THEN data->>'buyer_full_name' ELSE data->>'buyer_legal_name' END),'')=''
  THEN RAISE EXCEPTION 'RED_INVOICE_BUYER_INFORMATION_INCOMPLETE'; END IF;
 END IF;
 IF ($5 OR $7='ready' OR existing.status IN ('ready','exported','completed')) AND kind IN ('vn_tax','household_id') AND COALESCE(data->>'buyer_id','')<>'' THEN
  issue:=public.pos_buyer_number_issue('personal_id',data->>'buyer_id');
  IF issue IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_NUMBER_INVALID' USING DETAIL=issue::text; END IF;
 END IF;
 IF char_length(COALESCE(data->>'buyer_id',''))>64 OR char_length(number)>64 OR char_length(COALESCE(data->>'buyer_address',''))>500 OR char_length(COALESCE(data->>'buyer_legal_name',''))>300
 OR char_length(COALESCE(data->>'buyer_full_name',''))>300 OR char_length(COALESCE(data->>'buyer_email',''))>254
 OR char_length(COALESCE(data->>'buyer_email_cc',''))>1000 OR char_length(COALESCE(data->>'buyer_phone',''))>30
 OR char_length(COALESCE(data->>'source_note',''))>500 OR char_length(COALESCE(data->>'buyer_unit_code',''))>100 THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 prior_setting:=current_setting('globos.pos_buyer_explicit',true);PERFORM set_config('globos.pos_buyer_explicit','true',true);
 IF existing.id IS NULL THEN
  INSERT INTO public.red_invoice_intakes(order_id,store_id,tax_entity_id,receipt_ids,sale_at,gross_amount,payment_method,line_items_snapshot,status,
   buyer_number_type,buyer_number_value,buyer_tax_code,buyer_id,requested_by,updated_by)
  SELECT $2,$1,r.tax_entity_id,p.ids,p.sale_at,p.gross,p.method,COALESCE(items.lines,'[]'::jsonb),CASE WHEN $5 THEN 'ready' ELSE 'awaiting_information' END,
   kind,number,CASE WHEN kind NOT IN ('personal_id','passport') THEN number END,CASE WHEN kind IN ('personal_id','passport') THEN number END,actor.id,actor.id
  FROM public.restaurants r CROSS JOIN(SELECT array_agg(id::text ORDER BY created_at,id) ids,min(created_at) sale_at,sum(COALESCE(amount_portion,amount)) gross,
   string_agg(DISTINCT method,', ' ORDER BY method) method FROM public.payments WHERE order_id=$2 AND restaurant_id=$1 AND is_revenue) p
  CROSS JOIN(SELECT jsonb_agg(jsonb_build_object('order_item_id',id,'display_name',COALESCE(NULLIF(display_name,''),label,'Item'),
   'quantity',quantity,'unit_price',unit_price,'vat_rate',vat_rate,'vat_amount',vat_amount,'total_amount_ex_tax',total_amount_ex_tax,
   'paying_amount_inc_tax',paying_amount_inc_tax) ORDER BY created_at,id) lines FROM public.order_items WHERE order_id=$2 AND status<>'cancelled') items
  WHERE r.id=$1 AND p.sale_at IS NOT NULL RETURNING * INTO existing;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAID_RECEIPT_REQUIRED'; END IF;
 END IF;
 target_ids:=ARRAY[$2];
 IF v_request_id IS NOT NULL THEN
  SELECT array_agg(order_id) INTO target_ids FROM(SELECT order_id FROM public.direct_order_financials WHERE request_id=v_request_id
   UNION SELECT order_id FROM public.direct_order_payment_charges WHERE request_id=v_request_id AND order_id IS NOT NULL) s;
  PERFORM id FROM public.red_invoice_intakes WHERE order_id=ANY(target_ids) ORDER BY order_id FOR UPDATE;
  UPDATE public.direct_order_requests SET invoice_details=invoice_details||jsonb_build_object('requested',true,'pos_only',true,'buyer_confirmed',$5,'number_type',kind,'number_value',number,
   'tax_code',CASE WHEN kind IN ('personal_id','passport') THEN '' ELSE number END,'legal_name',COALESCE(data->>'buyer_legal_name',''),
   'full_name',COALESCE(data->>'buyer_full_name',''),'address',COALESCE(data->>'buyer_address',''),'email',COALESCE(data->>'buyer_email',''),
   'email_cc',COALESCE(data->>'buyer_email_cc',''),'phone',COALESCE(data->>'buyer_phone',''),'unit_code',COALESCE(data->>'buyer_unit_code',''),
   'buyer_id',CASE WHEN kind IN ('personal_id','passport') THEN number ELSE COALESCE(data->>'buyer_id','') END,'source_note',COALESCE(data->>'source_note','')),
   support_version=support_version+1 WHERE id=v_request_id;
 END IF;
 UPDATE public.red_invoice_intakes SET buyer_number_type=kind,buyer_number_value=number,
  buyer_tax_code=CASE WHEN kind NOT IN ('personal_id','passport') THEN number END,
  buyer_id=CASE WHEN kind IN ('personal_id','passport') THEN number ELSE NULLIF(data->>'buyer_id','') END,
  buyer_legal_name=NULLIF(data->>'buyer_legal_name',''),buyer_full_name=NULLIF(data->>'buyer_full_name',''),buyer_address=NULLIF(data->>'buyer_address',''),
  buyer_email=NULLIF(data->>'buyer_email',''),buyer_email_cc=NULLIF(data->>'buyer_email_cc',''),buyer_phone=NULLIF(data->>'buyer_phone',''),
  buyer_unit_code=NULLIF(data->>'buyer_unit_code',''),source_note=NULLIF(data->>'source_note',''),updated_at=clock_timestamp(),updated_by=actor.id,
  source=COALESCE($6,source),status=CASE WHEN status IN ('exported','completed') THEN status ELSE COALESCE($7,CASE WHEN $5 AND status='awaiting_information' THEN 'ready' ELSE status END) END,
  ready_at=CASE WHEN $5 OR $7='ready' THEN COALESCE(ready_at,now()) ELSE ready_at END
 WHERE store_id=$1 AND order_id=ANY(target_ids);
 PERFORM set_config('globos.pos_buyer_explicit',COALESCE(prior_setting,''),true);
 SELECT * INTO v FROM public.red_invoice_intakes WHERE id=existing.id;
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'pos_buyer_information_update','red_invoice_intakes',v.id,
  jsonb_build_object('order_id',$2,'store_id',$1,'previous_version',existing.buyer_version,'version',v.buyer_version,'changed_fields',ARRAY(SELECT jsonb_object_keys($4))));
 RETURN to_jsonb(v)||jsonb_build_object('store_name',(SELECT name FROM public.restaurants WHERE id=$1),
 'related_buyer_versions',(SELECT COALESCE(jsonb_object_agg(order_id::text,jsonb_build_object('version',buyer_version,'status',status)),'{}'::jsonb) FROM public.red_invoice_intakes WHERE store_id=$1 AND order_id=ANY(target_ids)));
END; $$;
REVOKE ALL ON FUNCTION public.pos_save_buyer_information(uuid,uuid,bigint,jsonb,boolean,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pos_save_buyer_information(uuid,uuid,bigint,jsonb,boolean,text,text) TO authenticated,service_role;


CREATE FUNCTION public.pos_sync_direct_buyer_information(p_store_id uuid,p_request_id uuid,p_order_ids uuid[] DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE b jsonb;ids uuid[];actor_id uuid;kind text;number text;complete boolean;prior text;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT invoice_details INTO b FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF b->>'requested' IS DISTINCT FROM 'true' THEN RETURN; END IF;
 IF EXISTS(SELECT 1 FROM public.restaurants WHERE id=$1 AND brand_id='77000000-0000-0000-0000-000000000001') THEN RETURN; END IF;
 SELECT id INTO actor_id FROM public.users WHERE auth_id=auth.uid() AND is_active LIMIT 1;
 kind:=COALESCE(b->>'number_type','vn_tax');number:=COALESCE(b->>'number_value',b->>'tax_code','');
 complete:=public.pos_buyer_number_issue(kind,number) IS NULL AND COALESCE(b->>'address','')<>'' AND COALESCE(b->>'phone','')<>''
 AND COALESCE(b->>'email','') LIKE '%@%' AND COALESCE(CASE WHEN kind IN ('personal_id','passport') THEN b->>'full_name' ELSE b->>'legal_name' END,'')<>'';
 SELECT array_agg(DISTINCT order_id) INTO ids FROM(SELECT order_id FROM public.direct_order_financials WHERE request_id=$2
 UNION ALL SELECT order_id FROM public.direct_order_payment_charges WHERE request_id=$2 AND order_id IS NOT NULL) s WHERE $3 IS NULL OR order_id=ANY($3);
 IF cardinality(ids) IS NULL THEN RETURN; END IF;
 PERFORM id FROM public.orders WHERE id=ANY(ids) AND restaurant_id=$1 ORDER BY id FOR UPDATE;
 PERFORM id FROM public.red_invoice_intakes WHERE order_id=ANY(ids) ORDER BY order_id FOR UPDATE;
 prior:=current_setting('globos.pos_buyer_explicit',true);PERFORM set_config('globos.pos_buyer_explicit','true',true);
 WITH paid AS(SELECT p.order_id,array_agg(p.id::text ORDER BY p.created_at,p.id) receipt_ids,min(p.created_at) sale_at,
 sum(COALESCE(p.amount_portion,p.amount)) gross_amount,string_agg(DISTINCT p.method,', ' ORDER BY p.method) method FROM public.payments p
 WHERE p.order_id=ANY(ids) AND p.restaurant_id=$1 AND p.is_revenue GROUP BY p.order_id),
 items AS(SELECT i.order_id,jsonb_agg(jsonb_build_object('order_item_id',i.id,'display_name',COALESCE(NULLIF(i.display_name,''),i.label,'Item'),
 'quantity',i.quantity,'unit_price',i.unit_price,'vat_rate',i.vat_rate,'vat_amount',i.vat_amount,'total_amount_ex_tax',i.total_amount_ex_tax,
 'paying_amount_inc_tax',i.paying_amount_inc_tax) ORDER BY i.created_at,i.id) lines FROM public.order_items i WHERE i.order_id=ANY(ids) AND i.status<>'cancelled' GROUP BY i.order_id)
 INSERT INTO public.red_invoice_intakes(order_id,store_id,tax_entity_id,receipt_ids,sale_at,gross_amount,payment_method,line_items_snapshot,
 source,status,buyer_number_type,buyer_number_value,buyer_tax_code,buyer_id,buyer_legal_name,buyer_full_name,buyer_address,buyer_email,
 buyer_email_cc,buyer_phone,buyer_unit_code,source_note,requested_by,updated_by,ready_at)
 SELECT paid.order_id,$1,r.tax_entity_id,paid.receipt_ids,paid.sale_at,paid.gross_amount,paid.method,COALESCE(items.lines,'[]'::jsonb),'cashier',
 CASE WHEN complete THEN 'ready' ELSE 'awaiting_information' END,kind,number,
 CASE WHEN kind NOT IN ('personal_id','passport') THEN NULLIF(number,'') END,CASE WHEN kind IN ('personal_id','passport') THEN NULLIF(number,'') ELSE NULLIF(b->>'buyer_id','') END,
 NULLIF(b->>'legal_name',''),NULLIF(b->>'full_name',''),NULLIF(b->>'address',''),NULLIF(b->>'email',''),NULLIF(b->>'email_cc',''),NULLIF(b->>'phone',''),
 NULLIF(b->>'unit_code',''),COALESCE(NULLIF(b->>'source_note',''),'Direct Order'),actor_id,actor_id,CASE WHEN complete THEN now() END
 FROM paid JOIN public.restaurants r ON r.id=$1 LEFT JOIN items ON items.order_id=paid.order_id
 ON CONFLICT(order_id) DO UPDATE SET buyer_number_type=EXCLUDED.buyer_number_type,buyer_number_value=EXCLUDED.buyer_number_value,
 buyer_tax_code=EXCLUDED.buyer_tax_code,buyer_id=CASE WHEN b?'buyer_id' OR kind IN ('personal_id','passport') THEN EXCLUDED.buyer_id ELSE red_invoice_intakes.buyer_id END,
 buyer_legal_name=EXCLUDED.buyer_legal_name,buyer_full_name=CASE WHEN b?'full_name' THEN EXCLUDED.buyer_full_name ELSE red_invoice_intakes.buyer_full_name END,
 buyer_address=EXCLUDED.buyer_address,buyer_email=EXCLUDED.buyer_email,buyer_email_cc=CASE WHEN b?'email_cc' THEN EXCLUDED.buyer_email_cc ELSE red_invoice_intakes.buyer_email_cc END,
 buyer_phone=EXCLUDED.buyer_phone,buyer_unit_code=CASE WHEN b?'unit_code' THEN EXCLUDED.buyer_unit_code ELSE red_invoice_intakes.buyer_unit_code END,
 source_note=CASE WHEN b?'source_note' THEN EXCLUDED.source_note ELSE red_invoice_intakes.source_note END,
 status=CASE WHEN red_invoice_intakes.status='awaiting_information' AND complete THEN 'ready' ELSE red_invoice_intakes.status END,
 ready_at=CASE WHEN complete THEN COALESCE(red_invoice_intakes.ready_at,now()) ELSE red_invoice_intakes.ready_at END,updated_by=actor_id,updated_at=now();
 PERFORM set_config('globos.pos_buyer_explicit',COALESCE(prior,''),true);
END; $$;
REVOKE ALL ON FUNCTION public.pos_sync_direct_buyer_information(uuid,uuid,uuid[]) FROM PUBLIC,anon,authenticated;

ALTER FUNCTION public.direct_order_sync_invoice_batch(uuid,uuid,uuid[]) RENAME TO direct_order_sync_invoice_before_pos_buyer;
CREATE FUNCTION public.direct_order_sync_invoice_batch(p_store_id uuid,p_request_id uuid,p_order_ids uuid[] DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE b jsonb;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT invoice_details INTO b FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF b->>'requested' IS DISTINCT FROM 'true' THEN RETURN; END IF;
 IF b->>'pos_only' IS DISTINCT FROM 'true' AND (COALESCE(b->>'tax_code','')='' OR public.pos_buyer_number_issue('vn_tax',b->>'tax_code') IS NULL) THEN
  PERFORM public.direct_order_sync_invoice_before_pos_buyer($1,$2,$3);
 END IF;
 PERFORM public.pos_sync_direct_buyer_information($1,$2,$3);
END; $$;
REVOKE ALL ON FUNCTION public.direct_order_sync_invoice_batch(uuid,uuid,uuid[]) FROM PUBLIC,anon,authenticated;

CREATE FUNCTION public.pos_direct_order_save_buyer(p_store_id uuid,p_request_id uuid,p_expected_version integer,p_patch jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE r public.direct_order_requests%ROWTYPE;kind text;number text;issue jsonb;
BEGIN
 PERFORM public.direct_order_require_actor($1,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 IF EXISTS(SELECT 1 FROM public.restaurants WHERE id=$1 AND brand_id='77000000-0000-0000-0000-000000000001') THEN RAISE EXCEPTION 'RED_INVOICE_DISABLED_FOR_PHOTO_OBJET'; END IF;
 SELECT * INTO r FROM public.direct_order_requests WHERE id=$2 AND restaurant_id=$1 FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF r.support_version IS DISTINCT FROM $3 THEN RAISE EXCEPTION 'POS_BUYER_CHANGED'; END IF;
 IF jsonb_typeof($4)<>'object' OR EXISTS(SELECT 1 FROM jsonb_each($4) e WHERE e.key NOT IN
 ('buyer_number_type','buyer_number_value','buyer_legal_name','buyer_full_name','buyer_address','buyer_email','buyer_email_cc','buyer_phone','buyer_unit_code','buyer_id','source_note') OR jsonb_typeof(e.value)<>'string') THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 kind:=$4->>'buyer_number_type';number:=$4->>'buyer_number_value';issue:=public.pos_buyer_number_issue(kind,number);
 IF issue IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_NUMBER_INVALID' USING DETAIL=issue::text; END IF;
 IF COALESCE($4->>'buyer_address','')='' OR COALESCE($4->>'buyer_phone','')='' OR COALESCE($4->>'buyer_email','') NOT LIKE '%@%'
 OR COALESCE(CASE WHEN kind IN ('personal_id','passport') THEN $4->>'buyer_full_name' ELSE $4->>'buyer_legal_name' END,'')=''
 THEN RAISE EXCEPTION 'RED_INVOICE_BUYER_INFORMATION_INCOMPLETE'; END IF;
 IF kind IN ('vn_tax','household_id') AND COALESCE($4->>'buyer_id','')<>'' AND public.pos_buyer_number_issue('personal_id',$4->>'buyer_id') IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_each_text($4) e WHERE char_length(e.value)>CASE e.key WHEN 'buyer_number_value' THEN 64 WHEN 'buyer_id' THEN 64 WHEN 'buyer_email' THEN 254 WHEN 'buyer_email_cc' THEN 1000 WHEN 'buyer_phone' THEN 30 WHEN 'buyer_legal_name' THEN 300 WHEN 'buyer_full_name' THEN 300 WHEN 'buyer_unit_code' THEN 100 ELSE 500 END) THEN RAISE EXCEPTION 'POS_BUYER_PATCH_INVALID'; END IF;
 UPDATE public.direct_order_requests SET invoice_details=invoice_details||jsonb_build_object('requested',true,'pos_only',true,'buyer_confirmed',true,'number_type',kind,'number_value',number,
 'tax_code',CASE WHEN kind IN ('personal_id','passport') THEN '' ELSE number END,'legal_name',$4->>'buyer_legal_name','full_name',$4->>'buyer_full_name',
 'address',$4->>'buyer_address','email',$4->>'buyer_email','email_cc',$4->>'buyer_email_cc','phone',$4->>'buyer_phone','unit_code',$4->>'buyer_unit_code',
 'buyer_id',CASE WHEN kind IN ('personal_id','passport') THEN number ELSE $4->>'buyer_id' END,'source_note',$4->>'source_note'),support_version=support_version+1
 WHERE id=$2 RETURNING * INTO r;
 PERFORM public.pos_sync_direct_buyer_information($1,$2);
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES(auth.uid(),'pos_direct_buyer_update','direct_order_requests',$2,jsonb_build_object('version',r.support_version));
 RETURN jsonb_build_object('version',r.support_version,'invoice',r.invoice_details);
END; $$;
REVOKE ALL ON FUNCTION public.pos_direct_order_save_buyer(uuid,uuid,integer,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pos_direct_order_save_buyer(uuid,uuid,integer,jsonb) TO authenticated,service_role;

-- Compatibility with older five-field clients: merging their partial payload
-- cannot erase the typed POS record or reactivate external invoice mutation.
CREATE FUNCTION public.pos_direct_buyer_source_guard() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
DECLARE b jsonb;issue jsonb;
BEGIN
 IF OLD.invoice_details->>'pos_only'='true' OR NEW.invoice_details->>'pos_only'='true' THEN
  b:=NEW.invoice_details;
  NEW.invoice_details:=OLD.invoice_details||b;
  IF NOT b?'number_value' AND b?'tax_code' AND b->>'tax_code' IS DISTINCT FROM OLD.invoice_details->>'tax_code' THEN
   NEW.invoice_details:=NEW.invoice_details||jsonb_build_object('number_type','vn_tax','number_value',b->>'tax_code');
  END IF;
  IF NEW.invoice_details->>'requested'='true' AND NEW.invoice_details->>'buyer_confirmed' IS DISTINCT FROM 'false' AND NEW.invoice_details IS DISTINCT FROM OLD.invoice_details THEN
   issue:=public.pos_buyer_number_issue(NEW.invoice_details->>'number_type',NEW.invoice_details->>'number_value');
   IF issue IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_NUMBER_INVALID' USING DETAIL=issue::text; END IF;
  END IF;
 END IF;
 RETURN NEW;
END; $$;
REVOKE ALL ON FUNCTION public.pos_direct_buyer_source_guard() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER pos_direct_buyer_source_guard BEFORE UPDATE OF invoice_details ON public.direct_order_requests
 FOR EACH ROW EXECUTE FUNCTION public.pos_direct_buyer_source_guard();

DO $verify$
BEGIN
 IF has_function_privilege('anon','public.pos_save_buyer_information(uuid,uuid,bigint,jsonb,boolean,text,text)','EXECUTE')
 OR public.pos_buyer_number_issue('vn_tax','0312345678-001') IS NOT NULL
 OR public.pos_buyer_number_issue('vn_tax','0312345678-000') IS NULL
 OR public.pos_buyer_number_issue('household_id','001234567890') IS NOT NULL THEN RAISE EXCEPTION 'POS_BUYER_POLICY_DRIFT'; END IF;
END; $verify$;

-- COMPONENT 20261010054000_pos_receipt_ledger.sql SHA256 c3e3786f9500e52e179002402207ba39e759a5209d9eebfee25de71504e7e5f8
-- POS ledger reads reuse the existing report scope. No external invoice API.
-- production-gate: self-verifying

SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='30s';
CREATE FUNCTION public.pos_restaurant_receipt_rows(p_business_date date,p_order_ids uuid[] DEFAULT NULL)
RETURNS TABLE(tax_entity_id uuid,seller_tax_code text,seller_legal_name text,is_sample_entity boolean,receipt_id text,store_id uuid,
 store_name text,receipt_source text,source_system text,sales_channel text,sold_at timestamptz,gross_sales numeric,payment_method text,
 is_red_invoice boolean,red_invoice_status text,buyer_tax_code text,buyer_legal_name text,buyer_address text,buyer_email text,buyer_phone text,line_items jsonb,receipt_number text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $rows$
  WITH candidates AS MATERIALIZED(
    SELECT DISTINCT payment.order_id FROM public.payments payment
    WHERE payment.is_revenue AND payment.created_at >= (p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh') AND payment.created_at < ((p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')
      AND (p_order_ids IS NULL OR payment.order_id=ANY(p_order_ids))
  ), paid_orders AS MATERIALIZED (
    SELECT
      payment.order_id,
      payment.restaurant_id AS store_id,
      max(payment.created_at) AS sold_at,
      round(sum(COALESCE(payment.amount_portion, payment.amount)), 2)
        AS gross_sales,
      array_agg(DISTINCT payment.method ORDER BY payment.method)
        AS payment_methods
    FROM public.payments payment JOIN candidates scope ON scope.order_id=payment.order_id
    JOIN public.orders issued_order
      ON issued_order.id = payment.order_id
     AND issued_order.status = 'completed'
    JOIN public.restaurants restaurant
      ON restaurant.id = payment.restaurant_id
     AND restaurant.brand_id IS DISTINCT FROM '77000000-0000-0000-0000-000000000001'::uuid
    WHERE payment.is_revenue = true
      AND restaurant.id <> '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid
      AND restaurant.tax_entity_id IS DISTINCT FROM '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid
    GROUP BY payment.order_id, payment.restaurant_id
    HAVING max(payment.created_at) >= (p_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')
       AND max(payment.created_at) < ((p_business_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')
  ),
  latest_jobs AS MATERIALIZED (
    SELECT DISTINCT ON(candidate.order_id) candidate.order_id,candidate.tax_entity_id,candidate.payment_method_snapshot,candidate.line_items_snapshot
    FROM public.meinvoice_jobs candidate JOIN paid_orders scope ON scope.order_id=candidate.order_id
    WHERE candidate.source_system='restaurant_pos' ORDER BY candidate.order_id,candidate.created_at DESC,candidate.id DESC
  ), historical_entities AS MATERIALIZED (
    SELECT DISTINCT ON(scope.order_id) scope.order_id,history.tax_entity_id
    FROM paid_orders scope JOIN public.store_tax_entity_history history ON history.store_id=scope.store_id
    AND history.effective_from<=scope.sold_at AND (history.effective_to IS NULL OR scope.sold_at<history.effective_to)
    ORDER BY scope.order_id,history.effective_from DESC,history.created_at DESC
  ), order_lines AS MATERIALIZED (
    SELECT item.order_id,jsonb_agg(jsonb_build_object('display_name',COALESCE(NULLIF(item.display_name,''),NULLIF(item.label,''),'Món ăn'),
    'item_type',item.item_type,'quantity',item.quantity,'unit_price',item.unit_price,'total_amount_ex_tax',item.total_amount_ex_tax,
    'vat_rate',item.vat_rate,'vat_amount',item.vat_amount) ORDER BY item.created_at,item.id) line_items
    FROM public.order_items item JOIN paid_orders scope ON scope.order_id=item.order_id
    WHERE item.status<>'cancelled' AND COALESCE(item.is_service_item,false)=false GROUP BY item.order_id
  ), receipt_candidates AS MATERIALIZED(
    SELECT scope.order_id,d.receipt_number,d.created_at,d.id FROM paid_orders scope
    JOIN public.digital_receipts d ON d.order_id=scope.order_id AND d.restaurant_id=scope.store_id
    UNION ALL
    SELECT scope.order_id,d.receipt_number,d.created_at,d.id FROM paid_orders scope JOIN public.payments p ON p.order_id=scope.order_id AND p.restaurant_id=scope.store_id AND p.is_revenue
    JOIN public.digital_receipts d ON d.combined_payment_group_id=p.combined_payment_group_id AND d.order_id IS NULL AND d.restaurant_id=scope.store_id
  ), receipt_numbers AS MATERIALIZED(
    SELECT DISTINCT ON(order_id) order_id,receipt_number FROM receipt_candidates ORDER BY order_id,created_at DESC,id DESC
  ), report_rows AS (
    SELECT
      seller.id AS tax_entity_id,
      seller.tax_code AS seller_tax_code,
      seller.name AS seller_legal_name,
      seller.id = '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid AS is_sample_entity,
      paid.order_id::text AS receipt_id,
      paid.store_id,
      restaurant.name AS store_name,
      'pos_payment'::text AS receipt_source,
      'restaurant_pos'::text AS source_system,
      orders.sales_channel,
      paid.sold_at,
      paid.gross_sales,
      COALESCE(
        NULLIF(btrim(job.payment_method_snapshot), ''),
        CASE WHEN cardinality(paid.payment_methods)<>1 THEN COALESCE(config.payment_method_mixed,'Tiền mặt/Thẻ/Ví điện tử')
        WHEN paid.payment_methods[1]='CASH' THEN COALESCE(config.payment_method_cash,'Tiền mặt')
        WHEN paid.payment_methods[1] IN ('CREDITCARD','ATM') THEN COALESCE(config.payment_method_card,'Thẻ quốc tế')
        ELSE COALESCE(config.payment_method_pay,'Ví điện tử/QR') END
      ) AS payment_method,
      intake.id IS NOT NULL AND intake.status <> 'cancelled'
        AS is_red_invoice,
      COALESCE(intake.status, '') AS red_invoice_status,
      COALESCE(intake.buyer_tax_code, '') AS buyer_tax_code,
      COALESCE(intake.buyer_legal_name, '') AS buyer_legal_name,
      COALESCE(intake.buyer_address, '') AS buyer_address,
      COALESCE(intake.buyer_email, '') AS buyer_email,
      COALESCE(intake.buyer_phone, '') AS buyer_phone,
      COALESCE(
        NULLIF(job.line_items_snapshot, '[]'::jsonb),
        order_lines.line_items,
        '[]'::jsonb
      ) AS line_items,
      COALESCE(receipt_number.receipt_number,'POS-'||upper(substr(replace(paid.order_id::text,'-',''),1,10))) AS receipt_number
    FROM paid_orders paid
    JOIN public.orders orders ON orders.id = paid.order_id
    JOIN public.restaurants restaurant ON restaurant.id = paid.store_id
    LEFT JOIN public.red_invoice_intakes intake
      ON intake.order_id = paid.order_id
    LEFT JOIN latest_jobs job ON job.order_id=paid.order_id
    LEFT JOIN historical_entities historical_entity ON historical_entity.order_id=paid.order_id
    JOIN public.tax_entity seller
      ON seller.id = CASE
        WHEN paid.store_id = '3a268807-771f-4fd4-84fe-e1b0b00de40a'::uuid THEN restaurant.tax_entity_id
        ELSE COALESCE(
          job.tax_entity_id,
          historical_entity.tax_entity_id,
          restaurant.tax_entity_id
        )
      END
    LEFT JOIN public.meinvoice_tax_entity_config config ON config.tax_entity_id=seller.id
    LEFT JOIN receipt_numbers receipt_number ON receipt_number.order_id=paid.order_id
    LEFT JOIN order_lines ON order_lines.order_id=paid.order_id
    WHERE seller.id <> '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'::uuid
  ) SELECT * FROM report_rows;

$rows$;
REVOKE ALL ON FUNCTION public.pos_restaurant_receipt_rows(date,uuid[]) FROM PUBLIC,anon,authenticated;
DO $patch$
DECLARE d text;start_at integer;end_at integer;
BEGIN
 SELECT pg_get_functiondef('public.get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure) INTO d;
 start_at:=strpos(d,'  WITH paid_orders AS (');end_at:=strpos(d,'  entity_rollups AS (');
 IF start_at=0 OR end_at<=start_at OR strpos(d,'IF p_business_date > v_hcm_now::date THEN')=0 OR strpos(d,'''item_type'', item.item_type')=0 THEN RAISE EXCEPTION 'POS_LEDGER_REPORT_ANCHOR_CHANGED'; END IF;
 EXECUTE substr(d,1,start_at-1)||'  WITH report_rows AS (SELECT * FROM public.pos_restaurant_receipt_rows(p_business_date)),
'||substr(d,end_at);
END; $patch$;

CREATE FUNCTION public.pos_receipt_ledger_batch(p_business_date date,p_tax_entity_id uuid,p_order_ids uuid[],p_red boolean)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v jsonb;n integer;
BEGIN
 IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN RAISE EXCEPTION 'SUPER_ADMIN_ONLY'; END IF;
 IF $1 IS NULL OR $1>(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date OR $2 IS NULL OR $4 IS NULL
 OR $3 IS NULL OR cardinality($3) NOT BETWEEN 1 AND 50 OR EXISTS(SELECT 1 FROM unnest($3) x WHERE x IS NULL)
 OR cardinality($3)<>(SELECT count(DISTINCT x) FROM unnest($3) x) THEN RAISE EXCEPTION 'POS_LEDGER_SCOPE_INVALID'; END IF;
 WITH scope AS MATERIALIZED(SELECT * FROM public.pos_restaurant_receipt_rows($1,$3) r WHERE r.tax_entity_id=$2 AND r.is_red_invoice=$4),
 payment_rows AS(SELECT p.order_id,jsonb_agg(jsonb_build_object('payment_id',p.id,'method',p.method,'amount',COALESCE(p.amount_portion,p.amount),
 'paid_at',p.created_at) ORDER BY p.created_at,p.id) rows FROM public.payments p JOIN scope s ON s.receipt_id=p.order_id::text AND s.store_id=p.restaurant_id
 WHERE p.is_revenue GROUP BY p.order_id)
 SELECT count(*),COALESCE(jsonb_agg(jsonb_build_object('order_id',s.receipt_id,'payments',p.rows,
 'buyer',CASE WHEN i.id IS NULL THEN NULL ELSE to_jsonb(i)-'meinvoice_job_id'-'export_batch_id'-'line_items_snapshot'-'receipt_ids'-'gross_amount'-'payment_method'-'tax_entity_id' END) ORDER BY s.sold_at,s.receipt_id),'[]'::jsonb)
 INTO n,v FROM scope s LEFT JOIN payment_rows p ON p.order_id::text=s.receipt_id LEFT JOIN public.red_invoice_intakes i ON i.order_id::text=s.receipt_id;
 IF n<>cardinality($3) THEN RAISE EXCEPTION 'POS_LEDGER_SCOPE_CHANGED'; END IF;
 RETURN jsonb_build_object('business_date',$1,'tax_entity_id',$2,'rows',v);
END; $$;
REVOKE ALL ON FUNCTION public.pos_receipt_ledger_batch(date,uuid,uuid[],boolean) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.pos_receipt_ledger_batch(date,uuid,uuid[],boolean) TO authenticated;
DO $verify$
DECLARE d text;
BEGIN
 SELECT pg_get_functiondef('public.get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure) INTO d;
 IF strpos(d,'LATERAL')<>0 OR strpos(d,'meinvoice_payment_method_label(')<>0 OR strpos(d,'is_super_admin()')=0
 OR strpos(d,'v_finalization.status')=0 OR has_function_privilege('anon','public.pos_receipt_ledger_batch(date,uuid,uuid[],boolean)','EXECUTE')
 THEN RAISE EXCEPTION 'POS_LEDGER_SCOPE_DRIFT'; END IF;
END; $verify$;

-- COMPONENT 20261011010000_bounded_data_reads.sql SHA256 68c963ee4cf1f673e30f38e3b86daf75f3f31cc3e6d1f41d75e62def9159b295

-- Read contracts keep the old entry points and grants for deployed clients.
-- Indexes serve bounded index probes, not one remote request per item.
CREATE INDEX IF NOT EXISTS inventory_po_line_history_scope_idx
  ON public.inventory_purchase_order_lines(supplier_item_id, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS inventory_receipt_line_history_idx
  ON public.inventory_receipt_lines(purchase_order_line_id);

CREATE OR REPLACE FUNCTION public.get_inventory_supplier_history_batch(
  p_purchase_order_id uuid, p_supplier_item_ids uuid[]
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = public, auth, pg_catalog AS $$
DECLARE v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'INVENTORY_HISTORY_FORBIDDEN'; END IF;
  IF p_purchase_order_id IS NULL OR COALESCE(cardinality(p_supplier_item_ids),0) NOT BETWEEN 1 AND 100
    OR array_ndims(p_supplier_item_ids) <> 1 OR array_position(p_supplier_item_ids,NULL) IS NOT NULL
    OR cardinality(p_supplier_item_ids) <> (SELECT count(DISTINCT id) FROM unnest(p_supplier_item_ids) id)
  THEN RAISE EXCEPTION 'INVENTORY_HISTORY_QUERY_INVALID'; END IF;
  -- Invoker RLS applies both to the source order and every history/receipt row.
  IF NOT EXISTS (SELECT 1 FROM public.inventory_purchase_orders WHERE id=p_purchase_order_id)
    OR EXISTS (SELECT 1 FROM unnest(p_supplier_item_ids) requested(id) WHERE NOT EXISTS (
      SELECT 1 FROM public.inventory_purchase_order_lines l
      WHERE l.purchase_order_id=p_purchase_order_id AND l.supplier_item_id=requested.id
    )) THEN RAISE EXCEPTION 'INVENTORY_HISTORY_FORBIDDEN'; END IF;
  WITH selected AS MATERIALIZED (
    SELECT recent.* FROM unnest(p_supplier_item_ids) requested(id)
    CROSS JOIN LATERAL (
      SELECT l.* FROM public.inventory_purchase_order_lines l
      WHERE l.supplier_item_id=requested.id AND l.purchase_order_id<>p_purchase_order_id
      ORDER BY l.created_at DESC,l.id DESC LIMIT 3
    ) recent
  ), received AS MATERIALIZED (
    SELECT rl.purchase_order_line_id,
      sum(rl.received_quantity_base) AS received_quantity_base,
      sum(rl.accepted_quantity_base) AS accepted_quantity_base,
      sum(rl.rejected_quantity_base) AS rejected_quantity_base,
      (array_agg(r.status ORDER BY COALESCE(r.received_at,r.created_at) DESC,r.id DESC))[1] AS last_receipt_status,
      max(COALESCE(r.received_at,r.created_at)) AS last_receipt_at
    FROM selected l JOIN public.inventory_receipt_lines rl ON rl.purchase_order_line_id=l.id
    JOIN public.inventory_receipts r ON r.id=rl.receipt_id
    GROUP BY rl.purchase_order_line_id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'supplier_item_id',l.supplier_item_id,'purchase_order_id',po.id,
    'purchase_order_no',po.purchase_order_no,'order_status',po.status,
    'ordered_at',po.created_at,'product_name',COALESCE(p.name,l.product_id::text,'-'),
    'ordered_quantity_base',l.ordered_quantity_base,'ordered_quantity_unit',l.ordered_quantity_unit,
    'order_unit',l.order_unit,'unit_price',l.unit_price,
    'received_quantity_base',COALESCE(r.received_quantity_base,0),
    'accepted_quantity_base',COALESCE(r.accepted_quantity_base,0),
    'rejected_quantity_base',COALESCE(r.rejected_quantity_base,0),
    'last_receipt_status',r.last_receipt_status,'last_receipt_at',r.last_receipt_at
  ) ORDER BY l.supplier_item_id,l.created_at DESC,l.id DESC),'[]') INTO v_result
  FROM selected l JOIN public.inventory_purchase_orders po ON po.id=l.purchase_order_id
  LEFT JOIN public.inventory_products p ON p.id=l.product_id
  LEFT JOIN received r ON r.purchase_order_line_id=l.id;
  RETURN jsonb_build_object('version',1,'rows',v_result);
END $$;
REVOKE ALL ON FUNCTION public.get_inventory_supplier_history_batch(uuid,uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_inventory_supplier_history_batch(uuid,uuid[]) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_store_menu_sales_analytics(
  p_store_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_menu_scope text
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_result jsonb;
  v_menu_scope text := lower(btrim(p_menu_scope));
BEGIN
  IF p_store_id IS NULL
     OR p_start_at IS NULL
     OR p_end_at IS NULL
     OR p_menu_scope IS NULL
     OR v_menu_scope NOT IN ('all', 'regular', 'combo')
     OR p_start_at >= p_end_at
     OR p_end_at > p_start_at + interval '366 days' THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_RANGE_INVALID';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  WITH candidate_orders AS MATERIALIZED (
    SELECT DISTINCT payment.order_id
    FROM public.payments payment
    WHERE payment.restaurant_id = p_store_id AND payment.is_revenue = true
      AND payment.created_at >= p_start_at AND payment.created_at < p_end_at
  ), paid_orders AS MATERIALIZED (
    SELECT
      order_row.id AS order_id,
      order_row.sales_channel,
      max(payment.created_at) AS paid_at
    FROM candidate_orders candidate
    JOIN public.orders order_row ON order_row.id = candidate.order_id
    JOIN public.payments payment
      ON payment.order_id = order_row.id
     AND payment.restaurant_id = order_row.restaurant_id
     AND payment.is_revenue = true
    WHERE order_row.restaurant_id = p_store_id
      AND order_row.status = 'completed'
    GROUP BY order_row.id, order_row.sales_channel
    HAVING max(payment.created_at) >= p_start_at
       AND max(payment.created_at) < p_end_at
  ),
  menu_lines AS MATERIALIZED (
    SELECT
      paid.order_id,
      paid.sales_channel,
      paid.paid_at,
      item.created_at AS line_created_at,
      CASE
        WHEN COALESCE(item.menu_item_id_snapshot, item.menu_item_id) IS NOT NULL
          THEN COALESCE(
            item.menu_item_id_snapshot,
            item.menu_item_id
          )::text
        ELSE 'name:' || md5(lower(btrim(COALESCE(
          NULLIF(item.display_name, ''),
          NULLIF(item.label, ''),
          'Unnamed menu'
        ))))
      END AS menu_key,
      CASE
        WHEN COALESCE(item.menu_item_id_snapshot, item.menu_item_id) IS NULL
          THEN 'name_fallback'
        ELSE 'stable_id'
      END AS identity_quality,
      COALESCE(
        NULLIF(btrim(item.display_name), ''),
        NULLIF(btrim(item.label), ''),
        'Unnamed menu'
      ) AS display_name,
      jsonb_array_length(
        COALESCE(item.combo_components, '[]'::jsonb)
      ) > 0 AS is_combo,
      item.quantity::bigint AS sold_quantity,
      COALESCE(item.paying_amount_inc_tax, 0)::numeric AS menu_sales_amount
    FROM paid_orders paid
    JOIN public.order_items item
      ON item.order_id = paid.order_id
     AND item.restaurant_id = p_store_id
    WHERE item.item_type = 'menu_item'
      AND item.status <> 'cancelled'
      AND COALESCE(item.is_service_item, false) = false
      AND CASE v_menu_scope
        WHEN 'regular' THEN jsonb_array_length(
          COALESCE(item.combo_components, '[]'::jsonb)
        ) = 0
        WHEN 'combo' THEN jsonb_array_length(
          COALESCE(item.combo_components, '[]'::jsonb)
        ) > 0
        ELSE true
      END
  ),
  menu_hours AS MATERIALIZED (
    SELECT
      line.menu_key,
      extract(hour FROM (
        line.paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh'
      ))::integer AS hour,
      sum(line.sold_quantity)::bigint AS sold_quantity,
      sum(line.menu_sales_amount)::numeric AS menu_sales_amount,
      count(DISTINCT line.order_id)::integer AS order_count
    FROM menu_lines line
    GROUP BY line.menu_key, hour
  ),
  menu_totals AS MATERIALIZED (
    SELECT
      line.menu_key,
      (array_agg(
        line.display_name
        ORDER BY line.paid_at DESC, line.line_created_at DESC, line.order_id
      ))[1] AS display_name,
      min(line.identity_quality) AS identity_quality,
      count(DISTINCT lower(btrim(line.display_name))) > 1
        AS name_changed_in_period,
      bool_or(line.is_combo) AS is_combo,
      sum(line.sold_quantity)::bigint AS sold_quantity,
      count(DISTINCT line.order_id)::integer AS order_count,
      sum(line.menu_sales_amount)::numeric AS menu_sales_amount,
      sum(line.sold_quantity) FILTER (
        WHERE line.sales_channel = 'dine_in'
      )::bigint AS dine_in_quantity,
      sum(line.sold_quantity) FILTER (
        WHERE line.sales_channel = 'takeaway'
      )::bigint AS takeaway_quantity,
      sum(line.sold_quantity) FILTER (
        WHERE line.sales_channel = 'delivery'
      )::bigint AS delivery_quantity
    FROM menu_lines line
    GROUP BY line.menu_key
  ),
  overall AS MATERIALIZED (
    SELECT
      count(DISTINCT line.order_id)::integer AS order_count,
      COALESCE(sum(line.sold_quantity), 0)::bigint AS sold_quantity,
      COALESCE(sum(line.sold_quantity) FILTER (
        WHERE line.is_combo
      ), 0)::bigint AS combo_sold_quantity,
      COALESCE(sum(line.menu_sales_amount), 0)::numeric
        AS menu_sales_amount,
      COALESCE(sum(line.menu_sales_amount) FILTER (
        WHERE line.is_combo
      ), 0)::numeric AS combo_menu_sales_amount,
      count(DISTINCT line.menu_key)::integer AS sold_menu_count,
      count(DISTINCT line.menu_key) FILTER (
        WHERE line.is_combo
      )::integer AS combo_sold_menu_count
    FROM menu_lines line
  ),
  ranked_menus AS MATERIALIZED (
    SELECT
      row_number() OVER (
        ORDER BY total.sold_quantity DESC,
          total.menu_sales_amount DESC,
          lower(total.display_name),
          total.menu_key
      )::integer AS rank,
      total.*,
      COALESCE(peak.hour, 0)::integer AS peak_hour
    FROM menu_totals total
    LEFT JOIN (
      SELECT DISTINCT ON (menu_key) menu_key, hour
      FROM menu_hours ORDER BY menu_key, sold_quantity DESC, hour
    ) peak ON peak.menu_key = total.menu_key
  ),
  hourly_totals AS MATERIALIZED (
    SELECT
      series.hour::integer AS hour,
      COALESCE(sum(line.sold_quantity), 0)::bigint AS sold_quantity,
      COALESCE(sum(line.menu_sales_amount), 0)::numeric
        AS menu_sales_amount,
      count(DISTINCT line.order_id)::integer AS order_count
    FROM generate_series(0, 23) AS series(hour)
    LEFT JOIN menu_lines line
      ON extract(hour FROM (
        line.paid_at AT TIME ZONE 'Asia/Ho_Chi_Minh'
      ))::integer = series.hour
    GROUP BY series.hour
  ),
  adjustments AS MATERIALIZED (
    SELECT
      count(*)::integer AS adjustment_count,
      COALESCE(sum(adjustment.amount), 0)::numeric AS adjustment_amount
    FROM public.payment_adjustments adjustment
    WHERE adjustment.restaurant_id = p_store_id
      AND adjustment.created_at >= p_start_at
      AND adjustment.created_at < p_end_at
  )
  SELECT jsonb_build_object(
    'summary', jsonb_build_object(
      'order_count', overall.order_count,
      'sold_quantity', overall.sold_quantity,
      'sold_menu_count', overall.sold_menu_count,
      'combo_sold_quantity', overall.combo_sold_quantity,
      'combo_sold_menu_count', overall.combo_sold_menu_count,
      'menu_sales_amount', overall.menu_sales_amount,
      'combo_menu_sales_amount', overall.combo_menu_sales_amount,
      'unallocated_adjustment_count', adjustments.adjustment_count,
      'unallocated_adjustment_amount', adjustments.adjustment_amount
    ),
    'menu_rows', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'rank', menu.rank,
        'menu_key', menu.menu_key,
        'display_name', menu.display_name,
        'name_ko', menu_item.name_ko,
        'name_vi', menu_item.name_vi,
        'name_en', menu_item.name_en,
        'identity_quality', menu.identity_quality,
        'name_changed_in_period', menu.name_changed_in_period,
        'is_combo', menu.is_combo,
        'sold_quantity', menu.sold_quantity,
        'order_count', menu.order_count,
        'menu_sales_amount', menu.menu_sales_amount,
        'quantity_share', CASE
          WHEN overall.sold_quantity = 0 THEN 0
          ELSE round(
            menu.sold_quantity::numeric / overall.sold_quantity * 100,
            2
          )
        END,
        'revenue_share', CASE
          WHEN overall.menu_sales_amount = 0 THEN 0
          ELSE round(
            menu.menu_sales_amount / overall.menu_sales_amount * 100,
            2
          )
        END,
        'peak_hour', menu.peak_hour,
        'dine_in_quantity', COALESCE(menu.dine_in_quantity, 0),
        'takeaway_quantity', COALESCE(menu.takeaway_quantity, 0),
        'delivery_quantity', COALESCE(menu.delivery_quantity, 0)
      ) ORDER BY menu.rank)
      FROM ranked_menus menu
      LEFT JOIN public.menu_items menu_item
        ON menu.menu_key = menu_item.id::text
        AND menu_item.restaurant_id = p_store_id
    ), '[]'::jsonb),
    'hour_rows', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'hour', hourly.hour,
        'sold_quantity', hourly.sold_quantity,
        'menu_sales_amount', hourly.menu_sales_amount,
        'order_count', hourly.order_count
      ) ORDER BY hourly.hour)
      FROM hourly_totals hourly
    ), '[]'::jsonb),
    'top_menu_hour_rows', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'rank', menu.rank,
        'menu_key', menu.menu_key,
        'display_name', menu.display_name,
        'name_ko', menu_item.name_ko,
        'name_vi', menu_item.name_vi,
        'name_en', menu_item.name_en,
        'hour', series.hour,
        'sold_quantity', COALESCE(hourly.sold_quantity, 0),
        'menu_sales_amount', COALESCE(hourly.menu_sales_amount, 0)
      ) ORDER BY menu.rank, series.hour)
      FROM ranked_menus menu
      LEFT JOIN public.menu_items menu_item
        ON menu.menu_key = menu_item.id::text
        AND menu_item.restaurant_id = p_store_id
      CROSS JOIN generate_series(0, 23) AS series(hour)
      LEFT JOIN menu_hours hourly
        ON hourly.menu_key = menu.menu_key
       AND hourly.hour = series.hour
      WHERE menu.rank <= 5
    ), '[]'::jsonb),
    'scope', jsonb_build_object(
      'aggregation_version', 3,
      'timezone', 'Asia/Ho_Chi_Minh',
      'payment_time_basis', 'last_revenue_payment',
      'menu_scope', v_menu_scope,
      'include_combos', v_menu_scope <> 'regular',
      'combo_identity_basis', 'order_item_combo_components_snapshot',
      'included_sources', jsonb_build_array('pos_orders'),
      'excluded_sources', jsonb_build_array(
        'external_sales',
        'photo_objet_sales'
      ),
      'adjustment_allocation', 'unallocated'
    )
  )
  INTO v_result
  FROM overall
  CROSS JOIN adjustments;

  RETURN v_result;
END;
$$;
CREATE OR REPLACE FUNCTION public.get_inventory_cost_analysis(
  p_store_id UUID,
  p_from DATE DEFAULT CURRENT_DATE - 6,
  p_to DATE DEFAULT CURRENT_DATE
) RETURNS TABLE (
  product_id UUID,
  product_name TEXT,
  category TEXT,
  consumed_quantity_base NUMERIC(12,3),
  consumed_amount NUMERIC(12,2),
  avg_unit_cost NUMERIC(12,4),
  preferred_unit_cost NUMERIC(12,4),
  cost_status TEXT
) AS $$
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_COST_ANALYSIS_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'INVENTORY_COST_ANALYSIS_DATE_RANGE_INVALID';
  END IF;

  RETURN QUERY
  WITH scoped_products AS MATERIALIZED (
    SELECT ip.* FROM public.inventory_products ip
    WHERE ip.restaurant_id = p_store_id AND ip.is_active = true
  ), consumption AS (
    SELECT
      idc.product_id,
      SUM(idc.consumed_quantity_base)::NUMERIC(12,3) AS consumed_quantity_base,
      SUM(idc.consumed_amount)::NUMERIC(12,2) AS consumed_amount
    FROM public.inventory_daily_consumption idc
    WHERE idc.restaurant_id = p_store_id
      AND idc.consumption_date BETWEEN p_from AND p_to
    GROUP BY idc.product_id
  ),
  supplier_cost AS (
    SELECT DISTINCT ON (isi.product_id)
      isi.product_id,
      ROUND(
        isi.unit_price / NULLIF(isi.order_unit_quantity_base, 0),
        4
      ) AS preferred_unit_cost
    FROM public.inventory_supplier_items isi
    JOIN scoped_products scoped ON scoped.id = isi.product_id
    WHERE isi.is_active = TRUE
      AND isi.order_unit_quantity_base > 0
    ORDER BY isi.product_id, isi.is_preferred DESC, isi.updated_at DESC
  )
  SELECT
    ip.id AS product_id,
    ip.name AS product_name,
    COALESCE(ip.category, '-') AS category,
    COALESCE(c.consumed_quantity_base, 0)::NUMERIC(12,3),
    COALESCE(c.consumed_amount, 0)::NUMERIC(12,2),
    CASE
      WHEN COALESCE(c.consumed_quantity_base, 0) <= 0 THEN 0
      ELSE ROUND(c.consumed_amount / c.consumed_quantity_base, 4)
    END AS avg_unit_cost,
    COALESCE(sc.preferred_unit_cost, 0)::NUMERIC(12,4),
    CASE
      WHEN COALESCE(c.consumed_amount, 0) = 0 THEN 'stable'
      WHEN sc.preferred_unit_cost IS NULL THEN 'missing_supplier_cost'
      WHEN c.consumed_amount / NULLIF(c.consumed_quantity_base, 0) > sc.preferred_unit_cost * 1.1 THEN 'warning'
      ELSE 'normal'
    END AS cost_status
  FROM scoped_products ip
  LEFT JOIN consumption c
    ON c.product_id = ip.id
  LEFT JOIN supplier_cost sc
    ON sc.product_id = ip.id
  WHERE ip.restaurant_id = p_store_id
    AND ip.is_active = TRUE
  ORDER BY COALESCE(c.consumed_amount, 0) DESC, lower(ip.name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- COMPONENT 20261011020000_employee_scoped_payroll.sql SHA256 37bda1f404faa74e8d6a0990ff4c7fbee2fca06a3b01e801aa2f574170a85320

CREATE OR REPLACE FUNCTION public.get_payroll_employee_attendance_page(
  p_store_id uuid,
  p_employee_id uuid,
  p_from timestamptz,
  p_to timestamptz,
  p_page_size integer DEFAULT 500,
  p_after_logged_at timestamptz DEFAULT NULL,
  p_after_id uuid DEFAULT NULL,
  p_expected_revision text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_rows jsonb;
  v_has_more boolean;
  v_revision text;
  v_total_count bigint;
BEGIN
  SELECT actor.* INTO v_actor
  FROM public.users actor
  WHERE actor.auth_id = auth.uid() AND actor.is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role IS NULL OR v_actor.role NOT IN (
    'admin', 'store_admin', 'brand_admin', 'super_admin',
    'photo_objet_master', 'photo_objet_store_admin',
    'photo_objet_store_operator'
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_VIEW_FORBIDDEN';
  END IF;

  IF p_employee_id IS NULL OR p_store_id IS NULL OR p_from IS NULL OR p_to IS NULL
     OR p_to <= p_from OR NOT isfinite(p_from) OR NOT isfinite(p_to)
     OR p_page_size IS NULL OR p_page_size NOT BETWEEN 1 AND 500
     OR (p_after_logged_at IS NULL) <> (p_after_id IS NULL)
     OR (p_after_id IS NULL) <> (p_expected_revision IS NULL)
     OR (p_after_logged_at IS NOT NULL AND
         (p_after_logged_at < p_from OR p_after_logged_at >= p_to))
     OR (p_expected_revision IS NOT NULL AND
         p_expected_revision !~ '^[0-9a-f]{32}$') THEN
    RAISE EXCEPTION 'ATTENDANCE_QUERY_INVALID';
  END IF;

  IF v_actor.role <> 'super_admin' AND NOT EXISTS (
    SELECT 1 FROM public.user_accessible_stores(auth.uid()) scope(store_id)
    WHERE scope.store_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_VIEW_FORBIDDEN';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(page) ORDER BY page.logged_at, page.id), '[]')
  INTO v_rows
  FROM (
    SELECT log.id, log.restaurant_id, log.user_id, log.employee_id,
      log.type, log.logged_at,
      COALESCE(NULLIF(btrim(employee.full_name), ''),
               NULLIF(btrim(legacy_user.full_name), ''),
               NULLIF(btrim(employee.employee_number), ''), '-') AS person_name,
      COALESCE(NULLIF(btrim(employee.employment_role), ''),
               NULLIF(btrim(legacy_user.role), ''), 'staff') AS person_role,
      employee.employee_number
    FROM public.attendance_logs log
    LEFT JOIN public.store_employees employee ON employee.id = log.employee_id
    LEFT JOIN public.users legacy_user ON legacy_user.id = log.user_id
    WHERE log.restaurant_id = p_store_id
      AND log.logged_at >= p_from AND log.logged_at < p_to
      AND (log.employee_id = p_employee_id OR (log.employee_id IS NULL AND log.user_id = p_employee_id))
      AND (p_after_id IS NULL OR
           (log.logged_at, log.id) > (p_after_logged_at, p_after_id))
    ORDER BY log.logged_at, log.id
    LIMIT p_page_size + 1
  ) page;

  v_has_more := jsonb_array_length(v_rows) > p_page_size;
  IF v_has_more THEN v_rows := v_rows - p_page_size; END IF;

  -- Compare the complete input only on the first and final pages: two scans,
  -- not one per page. xmin also detects edits that restore an earlier value.
  -- This is an optimistic read check, not a persistent exported MVCC snapshot.
  -- A change fails the entire calculation instead of returning a partial wage.
  IF p_after_id IS NULL OR NOT v_has_more THEN
    SELECT md5(p_store_id::text || ':' || p_employee_id::text || ':' || extract(epoch FROM p_from)::text ||
               ':' || extract(epoch FROM p_to)::text || ':' ||
               COALESCE(string_agg(
                 format('%s:%s:%s:%s', log.id, log.xmin::text,
                        employee.xmin::text, legacy_user.xmin::text),
                 ',' ORDER BY log.id), '')), count(*)
    INTO v_revision, v_total_count
    FROM public.attendance_logs log
    LEFT JOIN public.store_employees employee ON employee.id = log.employee_id
    LEFT JOIN public.users legacy_user ON legacy_user.id = log.user_id
    WHERE log.restaurant_id = p_store_id
      AND log.logged_at >= p_from AND log.logged_at < p_to
      AND (log.employee_id = p_employee_id OR (log.employee_id IS NULL AND log.user_id = p_employee_id));

    IF p_expected_revision IS NOT NULL AND v_revision <> p_expected_revision THEN
      RAISE EXCEPTION 'PAYROLL_ATTENDANCE_CHANGED';
    END IF;
  ELSE
    v_revision := p_expected_revision;
  END IF;

  RETURN jsonb_build_object('rows', v_rows, 'has_more', v_has_more,
                            'revision', v_revision, 'total_count', v_total_count);
END;
$$;
REVOKE ALL ON FUNCTION public.get_payroll_employee_attendance_page(uuid,uuid,timestamptz,timestamptz,integer,timestamptz,uuid,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_payroll_employee_attendance_page(uuid,uuid,timestamptz,timestamptz,integer,timestamptz,uuid,text) TO authenticated;
CREATE OR REPLACE FUNCTION public.get_employee_financial_input_page(
  p_source text,
  p_employee_id uuid,
  p_store_ids uuid[] DEFAULT NULL,
  p_from timestamptz DEFAULT NULL,
  p_to timestamptz DEFAULT NULL,
  p_from_date date DEFAULT NULL,
  p_to_date date DEFAULT NULL,
  p_cursor jsonb DEFAULT NULL,
  p_expected_revision text DEFAULT NULL,
  p_page_size integer DEFAULT 500
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_query text;
  v_order text;
  v_cursor text;
  v_after text;
  v_arity integer := 2;
  v_rows jsonb;
  v_has_more boolean;
  v_revision text;
  v_count bigint;
  v_context text;
BEGIN
  IF p_employee_id IS NULL OR p_source NOT IN ('staff','allowances') THEN RAISE EXCEPTION 'FINANCIAL_INPUT_QUERY_INVALID'; END IF;
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'FINANCIAL_INPUT_FORBIDDEN'; END IF;
  IF p_source IS NULL OR p_page_size IS NULL OR p_page_size NOT BETWEEN 1 AND 500
    OR (p_cursor IS NULL) <> (p_expected_revision IS NULL)
    OR (p_expected_revision IS NOT NULL AND p_expected_revision !~ '^[0-9a-f]{32}$') THEN
    RAISE EXCEPTION 'FINANCIAL_INPUT_QUERY_INVALID';
  END IF;

  IF p_source <> 'holidays' AND (
    COALESCE(cardinality(p_store_ids), 0) = 0
    OR EXISTS (
      SELECT 1 FROM unnest(p_store_ids) requested(id)
      WHERE requested.id IS NULL OR (NOT COALESCE(public.is_super_admin(), false) AND NOT EXISTS (
        SELECT 1 FROM public.user_accessible_stores(auth.uid()) allowed(id)
        WHERE allowed.id = requested.id
      ))
    )
  ) THEN RAISE EXCEPTION 'FINANCIAL_INPUT_FORBIDDEN'; END IF;

  IF p_source IN ('allowances', 'holidays', 'photoSales') AND (
    p_from_date IS NULL OR p_to_date IS NULL OR p_to_date < p_from_date
    OR NOT isfinite(p_from_date) OR NOT isfinite(p_to_date)
  ) THEN RAISE EXCEPTION 'FINANCIAL_INPUT_QUERY_INVALID'; END IF;
  IF p_source IN ('revenuePayments', 'servicePayments', 'externalSales',
                  'orders', 'cancelledItems', 'einvoiceJobs') AND (
    p_from IS NULL OR p_to IS NULL OR p_to <= p_from
    OR NOT isfinite(p_from) OR NOT isfinite(p_to)
  ) THEN RAISE EXCEPTION 'FINANCIAL_INPUT_QUERY_INVALID'; END IF;

  -- The derived table remains flattenable. Continuation predicates are added
  -- only for continuation pages, avoiding nullable OR predicates on index keys.
  CASE p_source
    WHEN 'staff' THEN
      v_query := 'SELECT id, store_id, employee_number, full_name, employment_role
        FROM public.store_employees WHERE store_id = ANY($1) AND is_active = true AND id = $9';
      v_order := 'q.id'; v_cursor := 'jsonb_build_array(q.id)';
      v_after := 'q.id > ($6->>0)::uuid'; v_arity := 1;
    WHEN 'allowances' THEN
      v_query := 'SELECT id, store_id, employee_id, work_date, is_split_shift,
        meal_allowance_amount, parking_allowance_amount
        FROM public.employee_daily_allowances WHERE store_id = ANY($1)
          AND work_date >= $4 AND work_date <= $5 AND employee_id = $9';
      v_order := 'q.work_date, q.id'; v_cursor := 'jsonb_build_array(q.work_date, q.id)';
      v_after := '(q.work_date, q.id) > (($6->>0)::date, ($6->>1)::uuid)';
    WHEN 'holidays' THEN
      v_query := 'SELECT holiday_date FROM public.vietnam_public_holidays
        WHERE is_active = true AND holiday_date >= $4 AND holiday_date <= $5';
      v_order := 'q.holiday_date'; v_cursor := 'jsonb_build_array(q.holiday_date)';
      v_after := 'q.holiday_date > ($6->>0)::date'; v_arity := 1;
    WHEN 'revenuePayments' THEN
      v_query := 'SELECT p.id, p.restaurant_id, p.order_id, p.amount, p.amount_portion,
        p.method, p.created_at, p.proof_required, p.proof_photo_url,
        CASE WHEN o.id IS NULL THEN NULL ELSE jsonb_build_object(''sales_channel'', o.sales_channel) END AS orders
        FROM public.payments p LEFT JOIN public.orders o ON o.id = p.order_id
        WHERE p.restaurant_id = ANY($1) AND p.is_revenue = true
          AND p.created_at >= $2 AND p.created_at < $3';
    WHEN 'servicePayments' THEN
      v_query := 'SELECT id, restaurant_id, amount, created_at FROM public.payments
        WHERE restaurant_id = ANY($1) AND is_revenue = false
          AND created_at >= $2 AND created_at < $3';
    WHEN 'externalSales' THEN
      v_query := 'SELECT id, restaurant_id, net_amount, completed_at FROM public.external_sales
        WHERE restaurant_id = ANY($1) AND is_revenue = true AND order_status = ''completed''
          AND completed_at >= $2 AND completed_at < $3';
      v_order := 'q.completed_at, q.id'; v_cursor := 'jsonb_build_array(q.completed_at, q.id)';
      v_after := '(q.completed_at, q.id) > (($6->>0)::timestamptz, ($6->>1)::uuid)';
    WHEN 'photoSales' THEN
      v_query := 'SELECT store_id, sale_date, total_gross_sales, total_transactions,
        total_service_amount FROM public.v_photo_objet_daily_summary
        WHERE store_id = ANY($1) AND sale_date >= $4 AND sale_date <= $5';
      v_order := 'q.sale_date, q.store_id'; v_cursor := 'jsonb_build_array(q.sale_date, q.store_id)';
      v_after := '(q.sale_date, q.store_id) > (($6->>0)::date, ($6->>1)::uuid)';
    WHEN 'orders' THEN
      v_query := 'SELECT id, restaurant_id, status, created_at FROM public.orders
        WHERE restaurant_id = ANY($1) AND created_at >= $2 AND created_at < $3';
    WHEN 'cancelledItems' THEN
      v_query := 'SELECT i.id, i.order_id, o.restaurant_id, o.created_at
        FROM public.order_items i JOIN public.orders o ON o.id = i.order_id
        WHERE i.status = ''cancelled'' AND o.restaurant_id = ANY($1)
          AND o.created_at >= $2 AND o.created_at < $3';
    WHEN 'einvoiceJobs' THEN
      v_query := 'SELECT id, store_id, order_id, status, error_message, manual_action_type,
        created_at FROM public.meinvoice_jobs
        WHERE store_id = ANY($1) AND created_at >= $2 AND created_at < $3';
    ELSE RAISE EXCEPTION 'FINANCIAL_INPUT_SOURCE_INVALID';
  END CASE;
  IF v_order IS NULL THEN
    v_order := 'q.created_at, q.id'; v_cursor := 'jsonb_build_array(q.created_at, q.id)';
    v_after := '(q.created_at, q.id) > (($6->>0)::timestamptz, ($6->>1)::uuid)';
  END IF;
  IF p_cursor IS NOT NULL THEN
    IF jsonb_typeof(p_cursor) <> 'array' THEN
      RAISE EXCEPTION 'FINANCIAL_INPUT_CURSOR_INVALID';
    END IF;
    IF jsonb_array_length(p_cursor) <> v_arity OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(p_cursor) element
      WHERE jsonb_typeof(element) <> 'string' OR element #>> '{}' = ''
    ) THEN RAISE EXCEPTION 'FINANCIAL_INPUT_CURSOR_INVALID'; END IF;
  END IF;

  EXECUTE format(
    'SELECT COALESCE(jsonb_agg(to_jsonb(page) ORDER BY %s), ''[]''::jsonb)
       FROM (SELECT q.*, %s AS _cursor FROM (%s) q %s ORDER BY %s LIMIT $7) page',
    replace(v_order, 'q.', 'page.'), v_cursor, v_query,
    CASE WHEN p_cursor IS NULL THEN '' ELSE 'WHERE ' || v_after END, v_order
  ) INTO v_rows
    USING p_store_ids, p_from, p_to, p_from_date, p_to_date, p_cursor, p_page_size + 1, NULL, p_employee_id;
  v_has_more := jsonb_array_length(v_rows) > p_page_size;
  IF v_has_more THEN v_rows := v_rows - p_page_size; END IF;

  -- Validate each dataset across its pages, without rescanning it on every page.
  -- Hash only the projected input values (also works for the existing RLS view).
  -- This is not a transaction spanning separate datasets or the whole report.
  IF p_cursor IS NULL OR NOT v_has_more THEN
    v_context := jsonb_build_array(p_source, auth.uid(), p_store_ids,
      p_from, p_to, p_from_date, p_to_date, p_employee_id)::text;
    EXECUTE format(
      'SELECT md5($8 || COALESCE(string_agg(md5(to_jsonb(q)::text), '''' ORDER BY %s), '''')), count(*)
         FROM (%s) q', v_order, v_query
    ) INTO v_revision, v_count
      USING p_store_ids, p_from, p_to, p_from_date, p_to_date, p_cursor, p_page_size, v_context, p_employee_id;
    IF p_expected_revision IS NOT NULL AND p_expected_revision <> v_revision THEN
      RAISE EXCEPTION 'FINANCIAL_INPUT_CHANGED';
    END IF;
  ELSE
    v_revision := p_expected_revision;
  END IF;
  RETURN jsonb_build_object('rows', v_rows, 'has_more', v_has_more,
    'revision', v_revision, 'total_count', v_count);
END;
$$;
REVOKE ALL ON FUNCTION public.get_employee_financial_input_page(text,uuid,uuid[],timestamptz,timestamptz,date,date,jsonb,text,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_employee_financial_input_page(text,uuid,uuid[],timestamptz,timestamptz,date,date,jsonb,text,integer) TO authenticated;

-- COMPONENT 20261011030000_fixed_account_exact_lookup.sql SHA256 2d83430545b9871119afdf3b31175e3480340e81d4038891e4fb4efa83031419

-- Reuse Supabase Auth users_instance_id_email_idx. Auth owns this table;
-- a normal postgres migration role must not try to create its indexes.
DO $$ BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='auth' AND tablename='users'
    AND indexname='users_instance_id_email_idx') THEN RAISE EXCEPTION 'FIXED_ACCOUNT_AUTH_INDEX_REQUIRED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='auth' AND table_name='users'
    AND column_name='is_sso_user') THEN RAISE EXCEPTION 'FIXED_ACCOUNT_AUTH_SCHEMA_REQUIRED'; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.find_fixed_account_auth_user(p_email text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth, pg_catalog AS $$
DECLARE v_result jsonb;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'FIXED_ACCOUNT_SERVICE_REQUIRED'; END IF;
  IF p_email IS NULL OR length(btrim(p_email)) NOT BETWEEN 3 AND 254 THEN RAISE EXCEPTION 'FIXED_ACCOUNT_EMAIL_INVALID'; END IF;
  SELECT jsonb_build_object('id',id,'email',email) INTO v_result
  FROM auth.users WHERE instance_id='00000000-0000-0000-0000-000000000000'::uuid
    AND lower(email)=lower(btrim(p_email)) AND is_sso_user=false ORDER BY id LIMIT 1;
  RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.find_fixed_account_auth_user(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.find_fixed_account_auth_user(text) TO service_role;

-- COMPONENT 20261011040000_report_summary_and_issue_pages.sql SHA256 46fc7d12c42a84d04605ee4aacde3fc98db16730ff679ab7675534916ffaae9d

CREATE OR REPLACE FUNCTION public.get_store_report_summary_v2(
  p_store_id uuid, p_from_date date, p_to_date date
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = public, auth, pg_catalog AS $$
DECLARE v_from timestamptz; v_to timestamptz; v_result jsonb;
BEGIN
  IF auth.uid() IS NULL OR p_store_id IS NULL OR (
    NOT COALESCE(public.is_super_admin(), false) AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(id) WHERE s.id = p_store_id
    )) THEN RAISE EXCEPTION 'STORE_REPORT_FORBIDDEN'; END IF;
  IF p_from_date IS NULL OR p_to_date IS NULL OR p_to_date < p_from_date
    OR NOT isfinite(p_from_date) OR NOT isfinite(p_to_date) THEN
    RAISE EXCEPTION 'STORE_REPORT_QUERY_INVALID';
  END IF;
  v_from := p_from_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_to := (p_to_date + 1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  WITH p AS MATERIALIZED (
    SELECT p.id, p.order_id, coalesce(p.amount,0) AS received,
      coalesce(p.amount_portion,p.amount,0) AS sales, p.created_at,
      (p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS day,
      extract(hour FROM p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::int AS hour,
      coalesce(lower(o.sales_channel::text),'') = 'delivery' AS delivery,
      coalesce('order:' || p.order_id::text, 'payment:' || p.id::text) AS tx,
      CASE lower(btrim(coalesce(p.method::text,'')))
        WHEN 'card' THEN 'CREDITCARD' WHEN 'credit_card' THEN 'CREDITCARD'
        WHEN 'pay' THEN 'OTHER' WHEN 'epay' THEN 'OTHER' WHEN 'e_pay' THEN 'OTHER'
        ELSE upper(btrim(coalesce(p.method::text,''))) END AS method,
      coalesce(p.proof_required,false) AS proof_required,
      btrim(coalesce(p.proof_photo_url,'')) <> '' AS proof_present
    FROM public.payments p LEFT JOIN public.orders o ON o.id = p.order_id
    WHERE p.restaurant_id = p_store_id AND p.is_revenue = true
      AND p.created_at >= v_from AND p.created_at < v_to
  ), e AS MATERIALIZED (
    SELECT coalesce(net_amount,0) AS sales,
      (completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS day,
      extract(hour FROM completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::int AS hour
    FROM public.external_sales WHERE restaurant_id = p_store_id AND is_revenue = true
      AND order_status = 'completed' AND completed_at >= v_from AND completed_at < v_to
  ), f AS MATERIALIZED (
    SELECT sale_date AS day,
      greatest(coalesce(total_gross_sales,0)-coalesce(total_service_amount,0),0) AS sales,
      coalesce(total_service_amount,0) AS service, coalesce(total_transactions,0) AS teams
    FROM public.v_photo_objet_daily_summary WHERE store_id = p_store_id
      AND sale_date >= p_from_date AND sale_date <= p_to_date
  ), day_contributions AS (
    SELECT day, coalesce(sum(sales) FILTER (WHERE NOT delivery),0) AS dine_in,
      coalesce(sum(sales) FILTER (WHERE delivery),0) AS delivery,
      count(DISTINCT tx) FILTER (WHERE NOT delivery) AS teams,
      coalesce(sum(received) FILTER (WHERE method='CASH'),0) AS cash,
      coalesce(sum(received) FILTER (WHERE method IN ('CREDITCARD','ATM')),0) AS card,
      coalesce(sum(received) FILTER (WHERE method='BANKTRANSFER'),0) AS bank,
      coalesce(sum(received) FILTER (WHERE method NOT IN ('CASH','CREDITCARD','ATM','BANKTRANSFER')),0) AS pay,
      sum(received-sales) AS variance FROM p GROUP BY day
    UNION ALL SELECT day,0,sum(sales),0,0,0,0,0,0 FROM e GROUP BY day
    UNION ALL SELECT day,sales,0,teams,0,0,0,0,0 FROM f
  ), daily AS (
    SELECT day, sum(dine_in) AS dine_in, sum(delivery) AS delivery, sum(teams) AS teams,
      sum(cash) AS cash, sum(card) AS card, sum(bank) AS bank, sum(pay) AS pay,
      sum(variance) AS variance FROM day_contributions GROUP BY day
  ), hourly AS (
    SELECT hour,sum(sales) AS amount FROM (
      SELECT hour,sales FROM p UNION ALL SELECT hour,sales FROM e
    ) h GROUP BY hour
  ), methods AS (
    SELECT coalesce(nullif(method,''),'UNKNOWN') AS method,
      count(DISTINCT tx) AS count,sum(received) AS amount,
      CASE WHEN count(*) FILTER (WHERE proof_required)=0 THEN 100::numeric ELSE
        100.0 * count(*) FILTER (WHERE proof_required AND proof_present)
          / count(*) FILTER (WHERE proof_required) END AS proof_pct
    FROM p GROUP BY coalesce(nullif(method,''),'UNKNOWN')
  ), order_counts AS (
    SELECT count(*) AS total,
      count(*) FILTER (WHERE lower(status::text)='completed') AS completed,
      count(*) FILTER (WHERE lower(status::text)='cancelled') AS cancelled,
      count(*) FILTER (WHERE coalesce(lower(status::text),'') NOT IN ('completed','cancelled')) AS open
    FROM public.orders WHERE restaurant_id=p_store_id AND created_at>=v_from AND created_at<v_to
  ), latest_payment AS (
    SELECT DISTINCT ON (order_id) order_id,id FROM p WHERE order_id IS NOT NULL
    ORDER BY order_id,created_at DESC,id DESC
  ), jobs AS MATERIALIZED (
    SELECT j.id,j.order_id,lp.id AS payment_id,j.status,j.created_at,
      NULL::text AS detail
    FROM public.meinvoice_jobs j LEFT JOIN latest_payment lp ON lp.order_id=j.order_id
    WHERE j.store_id=p_store_id AND j.created_at>=v_from AND j.created_at<v_to
      AND j.status IN ('failed','manual_action_required')
  ), stats AS (
    SELECT coalesce(sum(dine_in),0) AS dine_in,coalesce(sum(delivery),0) AS delivery,
      coalesce(sum(cash),0) AS cash,coalesce(sum(card),0) AS card,
      coalesce(sum(bank),0) AS bank,coalesce(sum(pay),0) AS pay,
      coalesce(sum(variance),0) AS variance FROM daily
  ), supplemental AS (
    SELECT (SELECT count(*) FROM e) + coalesce((SELECT sum(teams) FROM f),0) AS count
  )
  SELECT jsonb_build_object('version',2,'store_id',p_store_id,'from_date',p_from_date,'to_date',p_to_date,
    'dine_in',s.dine_in,'delivery',s.delivery,
    'service',coalesce((SELECT sum(amount) FROM public.payments
      WHERE restaurant_id=p_store_id AND is_revenue=false AND created_at>=v_from AND created_at<v_to),0)
      + coalesce((SELECT sum(service) FROM f),0),
    'cancelled_amount',public.get_store_sales_cancellation_total(p_store_id,v_from,v_to-interval '1 microsecond'),
    'total_orders',o.total+extra.count,'completed_orders',o.completed+extra.count,
    'paid_orders',(SELECT count(DISTINCT tx) FROM p)+extra.count,
    'open_orders',o.open,'cancelled_orders',o.cancelled,
    'cancelled_items',(SELECT count(*) FROM public.order_items i JOIN public.orders ord ON ord.id=i.order_id
      WHERE i.status='cancelled' AND ord.restaurant_id=p_store_id AND ord.created_at>=v_from AND ord.created_at<v_to),
    'cash',s.cash,'card',s.card,'bank',s.bank,'pay',s.pay,'variance',s.variance,
    'missing_proof_count',(SELECT count(*) FROM p WHERE proof_required AND NOT proof_present),
    'failed_einvoice_count',(SELECT count(*) FROM jobs),
    'proof_pct',(SELECT CASE WHEN count(*) FILTER (WHERE proof_required)=0 THEN 100::numeric ELSE
      100.0 * count(*) FILTER (WHERE proof_required AND proof_present) / count(*) FILTER (WHERE proof_required) END FROM p),
    'daily',coalesce((SELECT jsonb_agg(jsonb_build_object('date',day,'dine_in',dine_in,'delivery',delivery,
      'teams',teams,'cash',cash,'card',card,'bank',bank,'pay',pay,'variance',variance) ORDER BY day) FROM daily),'[]'::jsonb),
    'hourly',coalesce((SELECT jsonb_agg(jsonb_build_object('hour',hour,'amount',amount) ORDER BY hour) FROM hourly),'[]'::jsonb),
    'methods',coalesce((SELECT jsonb_agg(jsonb_build_object('method',method,'count',count,'amount',amount,
      'proof_pct',proof_pct) ORDER BY method) FROM methods),'[]'::jsonb),
    'missing_proof','[]'::jsonb,'einvoice_issues','[]'::jsonb
  ) INTO v_result FROM stats s CROSS JOIN order_counts o CROSS JOIN supplemental extra;
  RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.get_store_report_summary_v2(uuid,date,date) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_store_report_summary_v2(uuid,date,date) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_store_report_issue_page(
  p_store_id uuid, p_from_date date, p_to_date date, p_kind text,
  p_after_at timestamptz DEFAULT NULL, p_after_id uuid DEFAULT NULL, p_limit integer DEFAULT 50
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = public, auth, pg_catalog AS $$
DECLARE v_from timestamptz; v_to timestamptz; v_rows jsonb; v_more boolean;
BEGIN
  IF auth.uid() IS NULL OR p_store_id IS NULL OR (NOT COALESCE(public.is_super_admin(),false) AND NOT EXISTS (
    SELECT 1 FROM public.user_accessible_stores(auth.uid()) s(id) WHERE s.id=p_store_id
  )) THEN RAISE EXCEPTION 'STORE_REPORT_FORBIDDEN'; END IF;
  IF p_from_date IS NULL OR p_to_date IS NULL OR p_to_date<p_from_date
    OR NOT isfinite(p_from_date) OR NOT isfinite(p_to_date) OR p_kind NOT IN ('missing_proof','einvoice')
    OR p_kind IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100
    OR (p_after_at IS NULL)<>(p_after_id IS NULL) THEN RAISE EXCEPTION 'STORE_REPORT_QUERY_INVALID'; END IF;
  v_from:=p_from_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_to:=(p_to_date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  IF p_kind='missing_proof' THEN
    SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.created_at,q.id),'[]') INTO v_rows
    FROM (SELECT p.id,p.order_id,p.amount AS amount,
      CASE lower(btrim(COALESCE(p.method::text,''))) WHEN 'card' THEN 'CREDITCARD' WHEN 'credit_card' THEN 'CREDITCARD'
      WHEN 'pay' THEN 'OTHER' WHEN 'epay' THEN 'OTHER' WHEN 'e_pay' THEN 'OTHER' ELSE upper(btrim(COALESCE(p.method::text,''))) END AS method,
      p.created_at FROM public.payments p WHERE p.restaurant_id=p_store_id AND p.is_revenue=true
      AND p.created_at>=v_from AND p.created_at<v_to AND COALESCE(p.proof_required,false)
      AND btrim(COALESCE(p.proof_photo_url,''))='' AND (p_after_id IS NULL OR (p.created_at,p.id)>(p_after_at,p_after_id))
      ORDER BY p.created_at,p.id LIMIT p_limit+1) q;
  ELSE
    WITH page AS MATERIALIZED (
      SELECT j.id,j.order_id,j.status,j.created_at,COALESCE(NULLIF(btrim(j.error_message),''),btrim(j.manual_action_type),'') AS detail
      FROM public.meinvoice_jobs j WHERE j.store_id=p_store_id AND j.created_at>=v_from AND j.created_at<v_to
      AND j.status IN ('failed','manual_action_required') AND (p_after_id IS NULL OR (j.created_at,j.id)>(p_after_at,p_after_id))
      ORDER BY j.created_at,j.id LIMIT p_limit+1
    ), latest_payment AS (
      SELECT DISTINCT ON (p.order_id) p.order_id,p.id FROM public.payments p
      JOIN (SELECT DISTINCT order_id FROM page) wanted ON wanted.order_id=p.order_id
      WHERE p.restaurant_id=p_store_id AND p.is_revenue=true AND p.created_at>=v_from AND p.created_at<v_to
      ORDER BY p.order_id,p.created_at DESC,p.id DESC
    ) SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.created_at,q.id),'[]') INTO v_rows
      FROM (SELECT page.*,latest.id AS payment_id FROM page LEFT JOIN latest_payment latest ON latest.order_id=page.order_id)q;
  END IF;
  v_more:=jsonb_array_length(v_rows)>p_limit;
  IF v_more THEN v_rows:=v_rows-p_limit; END IF;
  RETURN jsonb_build_object('version',1,'rows',v_rows,'has_more',v_more);
END $$;
REVOKE ALL ON FUNCTION public.get_store_report_issue_page(uuid,date,date,text,timestamptz,uuid,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_store_report_issue_page(uuid,date,date,text,timestamptz,uuid,integer) TO authenticated;

-- COMPONENT 20261011050000_receipt_page_item_reads.sql SHA256 c1a7245330a6a6f7e599b61b6ccbbf19aeabba6f75c431165a9495597f70f555

CREATE OR REPLACE FUNCTION public.get_receipt_ledger(
  p_business_date date,
  p_store_id uuid DEFAULT NULL,
  p_query text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_limit integer DEFAULT 100,
  p_offset integer DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_business_date date := p_business_date;
  v_start timestamptz :=
    v_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_end timestamptz :=
    (v_business_date + 1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
  v_query text := NULLIF(btrim(COALESCE(p_query, '')), '');
  v_status text := NULLIF(lower(btrim(COALESCE(p_status, ''))), '');
  v_result jsonb;
BEGIN
  IF v_business_date IS NULL THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_BUSINESS_DATE_REQUIRED';
  END IF;

  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin' AND p_store_id IS NULL THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_STORE_REQUIRED';
  END IF;

  IF p_store_id IS NOT NULL
     AND v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) scope(store_id)
       WHERE scope.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_FORBIDDEN';
  END IF;

  WITH scoped_payments AS (
    SELECT
      payment.id,
      payment.order_id,
      payment.restaurant_id AS store_id,
      payment.combined_payment_group_id,
      CASE
        WHEN payment.combined_payment_group_id IS NULL
          THEN 'order:' || payment.order_id::text
        ELSE 'combined:' || payment.combined_payment_group_id::text
      END AS ledger_key,
      COALESCE(payment.amount_portion, payment.amount) AS amount,
      payment.method,
      COALESCE(payment_group.completed_at, payment.created_at) AS sold_at,
      COALESCE(
        NULLIF(user_row.fixed_account_code, ''),
        NULLIF(user_row.full_name, ''),
        'CASHIER'
      ) AS cashier_name
    FROM public.payments payment
    LEFT JOIN public.combined_payment_groups payment_group
      ON payment_group.id = payment.combined_payment_group_id
    LEFT JOIN public.users user_row
      ON user_row.auth_id = payment.processed_by
    WHERE payment.is_revenue = true
      AND COALESCE(payment_group.completed_at, payment.created_at) >= v_start
      AND COALESCE(payment_group.completed_at, payment.created_at) < v_end
      AND (p_store_id IS NULL OR payment.restaurant_id = p_store_id)
      AND (
        v_actor.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) scope(store_id)
          WHERE scope.store_id = payment.restaurant_id
        )
      )
  ),
  payment_adjustment_totals AS (
    SELECT
      payment.ledger_key,
      ROUND(COALESCE(sum(adjustment.amount), 0), 2) AS adjusted_amount
    FROM public.payment_adjustments adjustment
    JOIN scoped_payments payment ON payment.id = adjustment.payment_id
    GROUP BY payment.ledger_key
  ),
  pos_payment_groups AS (
    SELECT
      payment.ledger_key,
      payment.combined_payment_group_id,
      payment.store_id,
      max(payment.sold_at) AS sold_at,
      (array_agg(DISTINCT payment.order_id ORDER BY payment.order_id))[1]
        AS primary_order_id,
      array_agg(DISTINCT payment.order_id ORDER BY payment.order_id)
        AS order_ids,
      ROUND(sum(payment.amount), 2) AS gross_amount,
      (array_agg(
        payment.cashier_name
        ORDER BY payment.sold_at DESC, payment.id DESC
      ))[1] AS cashier_name
    FROM scoped_payments payment
    GROUP BY
      payment.ledger_key,
      payment.combined_payment_group_id,
      payment.store_id
  ),
  pos_payment_methods AS (
    SELECT
      payment.ledger_key,
      payment.method,
      ROUND(sum(payment.amount), 2) AS amount
    FROM scoped_payments payment
    GROUP BY payment.ledger_key, payment.method
  ),
  pos_payment_summaries AS (
    SELECT
      payment.ledger_key,
      jsonb_agg(jsonb_build_object(
        'method', payment.method,
        'amount', payment.amount
      ) ORDER BY payment.method) AS payments
    FROM pos_payment_methods payment
    GROUP BY payment.ledger_key
  ),
  pos_allocations AS (
    SELECT
      payment.ledger_key,
      payment.order_id,
      COALESCE(table_row.table_number, 'TAKEAWAY') AS table_number,
      ROUND(sum(payment.amount), 2) AS amount
    FROM scoped_payments payment
    JOIN public.orders order_row ON order_row.id = payment.order_id
    LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
    GROUP BY
      payment.ledger_key,
      payment.order_id,
      COALESCE(table_row.table_number, 'TAKEAWAY')
  ),
  pos_allocation_summaries AS (
    SELECT
      allocation.ledger_key,
      string_agg(
        allocation.table_number,
        ', ' ORDER BY allocation.table_number, allocation.order_id
      ) AS table_number,
      jsonb_agg(jsonb_build_object(
        'order_id', allocation.order_id,
        'table_number', allocation.table_number,
        'amount', allocation.amount
      ) ORDER BY allocation.table_number, allocation.order_id) AS allocations
    FROM pos_allocations allocation
    GROUP BY allocation.ledger_key
  ),
  all_receipts AS (
    SELECT
      COALESCE(
        receipt.id::text,
        COALESCE(
          payment_group.combined_payment_group_id,
          payment_group.primary_order_id
        )::text
      ) AS receipt_id,
      COALESCE(
        receipt.receipt_number,
        CASE
          WHEN payment_group.combined_payment_group_id IS NOT NULL THEN
            'BC-' || to_char(
              payment_group.sold_at AT TIME ZONE 'Asia/Ho_Chi_Minh',
              'YYYYMMDD'
            ) || '-' || lpad(((
              ('x' || substr(md5(
                payment_group.combined_payment_group_id::text
              ), 1, 8))::bit(32)::bigint % 1000000
            )::text), 6, '0')
          ELSE 'POS-' || upper(substr(replace(
            payment_group.primary_order_id::text, '-', ''
          ), 1, 10))
        END
      ) AS receipt_number,
      CASE
        WHEN payment_group.combined_payment_group_id IS NULL
          THEN payment_group.primary_order_id
        ELSE NULL::uuid
      END AS order_id,
      payment_group.combined_payment_group_id,
      to_jsonb(payment_group.order_ids) AS order_ids,
      payment_group.store_id,
      restaurant.name AS store_name,
      payment_group.sold_at,
      allocation.table_number,
      CASE
        WHEN payment_group.combined_payment_group_id IS NULL
          THEN primary_order.sales_channel
        ELSE 'combined'
      END AS sales_channel,
      payment_group.cashier_name,
      payment_summary.payments,
      allocation.allocations,
      '[]'::jsonb AS items,
      payment_group.gross_amount,
      LEAST(
        payment_group.gross_amount,
        COALESCE(adjustment.adjusted_amount, 0)
      ) AS adjusted_amount,
      GREATEST(
        payment_group.gross_amount - COALESCE(adjustment.adjusted_amount, 0),
        0
      ) AS net_amount,
      CASE
        WHEN COALESCE(adjustment.adjusted_amount, 0) >=
             payment_group.gross_amount THEN 'refunded'
        WHEN COALESCE(adjustment.adjusted_amount, 0) > 0
          THEN 'partially_refunded'
        ELSE 'paid'
      END AS receipt_status,
      'pos'::text AS receipt_source,
      CASE
        WHEN payment_group.combined_payment_group_id IS NULL
          THEN 'single'
        ELSE 'combined'
      END AS receipt_scope,
      true AS printable,
      receipt.id IS NOT NULL AS digital_receipt_ready,
      CASE
        WHEN payment_group.combined_payment_group_id IS NOT NULL THEN
          COALESCE(
            NULLIF(receipt.snapshot->>'received_amount', '')::numeric,
            payment_group.gross_amount
          )
        ELSE payment_group.gross_amount
      END AS received_amount
    FROM pos_payment_groups payment_group
    JOIN public.orders primary_order
      ON primary_order.id = payment_group.primary_order_id
    JOIN public.restaurants restaurant
      ON restaurant.id = payment_group.store_id
    JOIN pos_payment_summaries payment_summary
      ON payment_summary.ledger_key = payment_group.ledger_key
    JOIN pos_allocation_summaries allocation
      ON allocation.ledger_key = payment_group.ledger_key
    LEFT JOIN public.digital_receipts receipt ON (
      payment_group.combined_payment_group_id IS NOT NULL
      AND receipt.combined_payment_group_id =
        payment_group.combined_payment_group_id
      AND receipt.order_id IS NULL
    ) OR (
      payment_group.combined_payment_group_id IS NULL
      AND receipt.order_id = payment_group.primary_order_id
    )
    LEFT JOIN payment_adjustment_totals adjustment
      ON adjustment.ledger_key = payment_group.ledger_key

    UNION ALL

    SELECT
      external.id::text,
      COALESCE(NULLIF(external.external_order_id, ''), external.id::text),
      NULL::uuid,
      NULL::uuid,
      '[]'::jsonb,
      external.restaurant_id,
      restaurant.name,
      COALESCE(external.completed_at, external.created_at),
      '-'::text,
      external.sales_channel,
      external.source_system,
      jsonb_build_array(jsonb_build_object(
        'method', external.source_system,
        'amount', external.net_amount
      )),
      '[]'::jsonb,
      '[]'::jsonb,
      external.gross_amount,
      GREATEST(external.gross_amount - external.net_amount, 0),
      external.net_amount,
      CASE external.order_status
        WHEN 'completed' THEN 'paid'
        WHEN 'partially_refunded' THEN 'partially_refunded'
        ELSE 'refunded'
      END,
      'external'::text,
      'external'::text,
      false,
      false,
      external.gross_amount
    FROM public.external_sales external
    JOIN public.restaurants restaurant
      ON restaurant.id = external.restaurant_id
    WHERE external.is_revenue = true
      AND COALESCE(external.completed_at, external.created_at) >= v_start
      AND COALESCE(external.completed_at, external.created_at) < v_end
      AND (p_store_id IS NULL OR external.restaurant_id = p_store_id)
      AND (
        v_actor.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) scope(store_id)
          WHERE scope.store_id = external.restaurant_id
        )
      )
  ),
  filtered_receipts AS (
    SELECT *
    FROM all_receipts receipt
    WHERE (v_status IS NULL OR receipt.receipt_status = v_status)
      AND (
        v_query IS NULL
        OR receipt.receipt_number ILIKE '%' || v_query || '%'
        OR receipt.store_name ILIKE '%' || v_query || '%'
        OR receipt.table_number ILIKE '%' || v_query || '%'
        OR COALESCE(receipt.order_id::text, '') ILIKE '%' || v_query || '%'
        OR COALESCE(receipt.combined_payment_group_id::text, '')
          ILIKE '%' || v_query || '%'
        OR receipt.order_ids::text ILIKE '%' || v_query || '%'
        OR receipt.allocations::text ILIKE '%' || v_query || '%'
      )
  ),
  page AS (
    SELECT *
    FROM filtered_receipts
    ORDER BY sold_at DESC, receipt_id DESC
    LIMIT v_limit OFFSET v_offset
  ),
  pos_order_keys AS (
    SELECT DISTINCT
      payment.ledger_key,
      payment.combined_payment_group_id,
      payment.order_id,
      payment.store_id
    FROM scoped_payments payment
    JOIN page selected ON selected.receipt_source='pos' AND payment.ledger_key = CASE
      WHEN selected.combined_payment_group_id IS NULL THEN 'order:'||selected.order_id::text
      ELSE 'combined:'||selected.combined_payment_group_id::text END
  ),
  pos_order_items AS (
    SELECT
      order_key.ledger_key,
      jsonb_agg(jsonb_build_object(
        'order_id', item.order_id,
        'table_number', COALESCE(table_row.table_number, 'TAKEAWAY'),
        'name', CASE
          WHEN order_key.combined_payment_group_id IS NULL THEN COALESCE(
            NULLIF(item.display_name, ''), NULLIF(item.label, ''), 'Item'
          )
          ELSE '[' || COALESCE(table_row.table_number, 'TAKEAWAY') || '] ' ||
            COALESCE(
              NULLIF(item.display_name, ''), NULLIF(item.label, ''), 'Item'
            )
        END,
        'name_ko', CASE WHEN NULLIF(btrim(menu_item.name_ko), '') IS NOT NULL THEN
          CASE WHEN order_key.combined_payment_group_id IS NULL THEN ''
            ELSE '[' || COALESCE(table_row.table_number, 'TAKEAWAY') || '] ' END
          || menu_item.name_ko END,
        'name_vi', CASE WHEN NULLIF(btrim(menu_item.name_vi), '') IS NOT NULL THEN
          CASE WHEN order_key.combined_payment_group_id IS NULL THEN ''
            ELSE '[' || COALESCE(table_row.table_number, 'TAKEAWAY') || '] ' END
          || menu_item.name_vi END,
        'name_en', CASE WHEN NULLIF(btrim(menu_item.name_en), '') IS NOT NULL THEN
          CASE WHEN order_key.combined_payment_group_id IS NULL THEN ''
            ELSE '[' || COALESCE(table_row.table_number, 'TAKEAWAY') || '] ' END
          || menu_item.name_en END,
        'quantity', item.quantity,
        'unit_price', item.unit_price
      ) ORDER BY
        COALESCE(table_row.table_number, 'TAKEAWAY'),
        item.created_at,
        item.id
      ) AS items
    FROM pos_order_keys order_key
    JOIN public.orders order_row ON order_row.id = order_key.order_id
    LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
    JOIN public.order_items item ON item.order_id = order_key.order_id
    LEFT JOIN public.menu_items menu_item
      ON menu_item.id = COALESCE(item.menu_item_id_snapshot, item.menu_item_id)
      AND menu_item.restaurant_id = item.restaurant_id
    WHERE item.status <> 'cancelled'
    GROUP BY order_key.ledger_key
  ),
  summary AS (
    SELECT
      count(*)::integer AS receipt_count,
      ROUND(COALESCE(sum(gross_amount), 0), 2) AS gross_amount,
      ROUND(COALESCE(sum(adjusted_amount), 0), 2) AS adjusted_amount,
      ROUND(COALESCE(sum(net_amount), 0), 2) AS net_amount
    FROM all_receipts
  )
  SELECT jsonb_build_object(
    'business_date', v_business_date,
    'generated_at', statement_timestamp(),
    'summary', jsonb_build_object(
      'receipt_count', summary.receipt_count,
      'gross_amount', summary.gross_amount,
      'adjusted_amount', summary.adjusted_amount,
      'net_amount', summary.net_amount
    ),
    'receipts', COALESCE(
      (SELECT jsonb_agg(to_jsonb(page)||jsonb_build_object('items',COALESCE(detail.items,'[]'::jsonb)) ORDER BY page.sold_at DESC,page.receipt_id DESC)
         FROM page LEFT JOIN pos_order_items detail ON detail.ledger_key=CASE
           WHEN page.combined_payment_group_id IS NULL THEN 'order:'||page.order_id::text
           ELSE 'combined:'||page.combined_payment_group_id::text END),
      '[]'::jsonb
    ),
    'has_more',
      (SELECT count(*) FROM filtered_receipts) > v_offset + v_limit
  ) INTO v_result
  FROM summary;

  RETURN v_result;
END;
$$;
CREATE OR REPLACE FUNCTION public.get_receipt_ledger_page(
  p_business_date date,
  p_store_id uuid DEFAULT NULL,
  p_query text DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0,
  p_after_at timestamptz DEFAULT NULL,
  p_after_id text DEFAULT NULL,
  p_include_summary boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_business_date date := p_business_date;
  v_start timestamptz :=
    v_business_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_end timestamptz :=
    (v_business_date + 1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_limit integer := LEAST(GREATEST(COALESCE(p_limit, 50), 1), 100);
  v_offset integer := GREATEST(COALESCE(p_offset, 0), 0);
  v_query text := NULLIF(btrim(COALESCE(p_query, '')), '');
  v_status text := NULLIF(lower(btrim(COALESCE(p_status, ''))), '');
  v_result jsonb;
BEGIN
  IF (p_after_at IS NULL) <> (p_after_id IS NULL) OR (p_after_at IS NOT NULL AND NOT isfinite(p_after_at)) OR p_include_summary IS NULL THEN RAISE EXCEPTION 'RECEIPT_LEDGER_CURSOR_INVALID'; END IF;
  IF v_business_date IS NULL THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_BUSINESS_DATE_REQUIRED';
  END IF;

  SELECT * INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid() AND is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
  ) THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin' AND p_store_id IS NULL THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_STORE_REQUIRED';
  END IF;

  IF p_store_id IS NOT NULL
     AND v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) scope(store_id)
       WHERE scope.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'RECEIPT_LEDGER_FORBIDDEN';
  END IF;

  WITH scoped_payments AS (
    SELECT
      payment.id,
      payment.order_id,
      payment.restaurant_id AS store_id,
      payment.combined_payment_group_id,
      CASE
        WHEN payment.combined_payment_group_id IS NULL
          THEN 'order:' || payment.order_id::text
        ELSE 'combined:' || payment.combined_payment_group_id::text
      END AS ledger_key,
      COALESCE(payment.amount_portion, payment.amount) AS amount,
      payment.method,
      COALESCE(payment_group.completed_at, payment.created_at) AS sold_at,
      COALESCE(
        NULLIF(user_row.fixed_account_code, ''),
        NULLIF(user_row.full_name, ''),
        'CASHIER'
      ) AS cashier_name
    FROM public.payments payment
    LEFT JOIN public.combined_payment_groups payment_group
      ON payment_group.id = payment.combined_payment_group_id
    LEFT JOIN public.users user_row
      ON user_row.auth_id = payment.processed_by
    WHERE payment.is_revenue = true
      AND COALESCE(payment_group.completed_at, payment.created_at) >= v_start
      AND COALESCE(payment_group.completed_at, payment.created_at) < v_end
      AND (p_store_id IS NULL OR payment.restaurant_id = p_store_id)
      AND (
        v_actor.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) scope(store_id)
          WHERE scope.store_id = payment.restaurant_id
        )
      )
  ),
  payment_adjustment_totals AS (
    SELECT
      payment.ledger_key,
      ROUND(COALESCE(sum(adjustment.amount), 0), 2) AS adjusted_amount
    FROM public.payment_adjustments adjustment
    JOIN scoped_payments payment ON payment.id = adjustment.payment_id
    GROUP BY payment.ledger_key
  ),
  pos_payment_groups AS (
    SELECT
      payment.ledger_key,
      payment.combined_payment_group_id,
      payment.store_id,
      max(payment.sold_at) AS sold_at,
      (array_agg(DISTINCT payment.order_id ORDER BY payment.order_id))[1]
        AS primary_order_id,
      array_agg(DISTINCT payment.order_id ORDER BY payment.order_id)
        AS order_ids,
      ROUND(sum(payment.amount), 2) AS gross_amount,
      (array_agg(
        payment.cashier_name
        ORDER BY payment.sold_at DESC, payment.id DESC
      ))[1] AS cashier_name
    FROM scoped_payments payment
    GROUP BY
      payment.ledger_key,
      payment.combined_payment_group_id,
      payment.store_id
  ),
  pos_payment_methods AS (
    SELECT
      payment.ledger_key,
      payment.method,
      ROUND(sum(payment.amount), 2) AS amount
    FROM scoped_payments payment
    GROUP BY payment.ledger_key, payment.method
  ),
  pos_payment_summaries AS (
    SELECT
      payment.ledger_key,
      jsonb_agg(jsonb_build_object(
        'method', payment.method,
        'amount', payment.amount
      ) ORDER BY payment.method) AS payments
    FROM pos_payment_methods payment
    GROUP BY payment.ledger_key
  ),
  pos_allocations AS (
    SELECT
      payment.ledger_key,
      payment.order_id,
      COALESCE(table_row.table_number, 'TAKEAWAY') AS table_number,
      ROUND(sum(payment.amount), 2) AS amount
    FROM scoped_payments payment
    JOIN public.orders order_row ON order_row.id = payment.order_id
    LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
    GROUP BY
      payment.ledger_key,
      payment.order_id,
      COALESCE(table_row.table_number, 'TAKEAWAY')
  ),
  pos_allocation_summaries AS (
    SELECT
      allocation.ledger_key,
      string_agg(
        allocation.table_number,
        ', ' ORDER BY allocation.table_number, allocation.order_id
      ) AS table_number,
      jsonb_agg(jsonb_build_object(
        'order_id', allocation.order_id,
        'table_number', allocation.table_number,
        'amount', allocation.amount
      ) ORDER BY allocation.table_number, allocation.order_id) AS allocations
    FROM pos_allocations allocation
    GROUP BY allocation.ledger_key
  ),
  all_receipts AS (
    SELECT
      COALESCE(
        receipt.id::text,
        COALESCE(
          payment_group.combined_payment_group_id,
          payment_group.primary_order_id
        )::text
      ) AS receipt_id,
      COALESCE(
        receipt.receipt_number,
        CASE
          WHEN payment_group.combined_payment_group_id IS NOT NULL THEN
            'BC-' || to_char(
              payment_group.sold_at AT TIME ZONE 'Asia/Ho_Chi_Minh',
              'YYYYMMDD'
            ) || '-' || lpad(((
              ('x' || substr(md5(
                payment_group.combined_payment_group_id::text
              ), 1, 8))::bit(32)::bigint % 1000000
            )::text), 6, '0')
          ELSE 'POS-' || upper(substr(replace(
            payment_group.primary_order_id::text, '-', ''
          ), 1, 10))
        END
      ) AS receipt_number,
      CASE
        WHEN payment_group.combined_payment_group_id IS NULL
          THEN payment_group.primary_order_id
        ELSE NULL::uuid
      END AS order_id,
      payment_group.combined_payment_group_id,
      to_jsonb(payment_group.order_ids) AS order_ids,
      payment_group.store_id,
      restaurant.name AS store_name,
      payment_group.sold_at,
      allocation.table_number,
      CASE
        WHEN payment_group.combined_payment_group_id IS NULL
          THEN primary_order.sales_channel
        ELSE 'combined'
      END AS sales_channel,
      payment_group.cashier_name,
      payment_summary.payments,
      allocation.allocations,
      '[]'::jsonb AS items,
      payment_group.gross_amount,
      LEAST(
        payment_group.gross_amount,
        COALESCE(adjustment.adjusted_amount, 0)
      ) AS adjusted_amount,
      GREATEST(
        payment_group.gross_amount - COALESCE(adjustment.adjusted_amount, 0),
        0
      ) AS net_amount,
      CASE
        WHEN COALESCE(adjustment.adjusted_amount, 0) >=
             payment_group.gross_amount THEN 'refunded'
        WHEN COALESCE(adjustment.adjusted_amount, 0) > 0
          THEN 'partially_refunded'
        ELSE 'paid'
      END AS receipt_status,
      'pos'::text AS receipt_source,
      CASE
        WHEN payment_group.combined_payment_group_id IS NULL
          THEN 'single'
        ELSE 'combined'
      END AS receipt_scope,
      true AS printable,
      receipt.id IS NOT NULL AS digital_receipt_ready,
      CASE
        WHEN payment_group.combined_payment_group_id IS NOT NULL THEN
          COALESCE(
            NULLIF(receipt.snapshot->>'received_amount', '')::numeric,
            payment_group.gross_amount
          )
        ELSE payment_group.gross_amount
      END AS received_amount
    FROM pos_payment_groups payment_group
    JOIN public.orders primary_order
      ON primary_order.id = payment_group.primary_order_id
    JOIN public.restaurants restaurant
      ON restaurant.id = payment_group.store_id
    JOIN pos_payment_summaries payment_summary
      ON payment_summary.ledger_key = payment_group.ledger_key
    JOIN pos_allocation_summaries allocation
      ON allocation.ledger_key = payment_group.ledger_key
    LEFT JOIN public.digital_receipts receipt ON (
      payment_group.combined_payment_group_id IS NOT NULL
      AND receipt.combined_payment_group_id =
        payment_group.combined_payment_group_id
      AND receipt.order_id IS NULL
    ) OR (
      payment_group.combined_payment_group_id IS NULL
      AND receipt.order_id = payment_group.primary_order_id
    )
    LEFT JOIN payment_adjustment_totals adjustment
      ON adjustment.ledger_key = payment_group.ledger_key

    UNION ALL

    SELECT
      external.id::text,
      COALESCE(NULLIF(external.external_order_id, ''), external.id::text),
      NULL::uuid,
      NULL::uuid,
      '[]'::jsonb,
      external.restaurant_id,
      restaurant.name,
      COALESCE(external.completed_at, external.created_at),
      '-'::text,
      external.sales_channel,
      external.source_system,
      jsonb_build_array(jsonb_build_object(
        'method', external.source_system,
        'amount', external.net_amount
      )),
      '[]'::jsonb,
      '[]'::jsonb,
      external.gross_amount,
      GREATEST(external.gross_amount - external.net_amount, 0),
      external.net_amount,
      CASE external.order_status
        WHEN 'completed' THEN 'paid'
        WHEN 'partially_refunded' THEN 'partially_refunded'
        ELSE 'refunded'
      END,
      'external'::text,
      'external'::text,
      false,
      false,
      external.gross_amount
    FROM public.external_sales external
    JOIN public.restaurants restaurant
      ON restaurant.id = external.restaurant_id
    WHERE external.is_revenue = true
      AND COALESCE(external.completed_at, external.created_at) >= v_start
      AND COALESCE(external.completed_at, external.created_at) < v_end
      AND (p_store_id IS NULL OR external.restaurant_id = p_store_id)
      AND (
        v_actor.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) scope(store_id)
          WHERE scope.store_id = external.restaurant_id
        )
      )
  ),
  filtered_receipts AS (
    SELECT *
    FROM all_receipts receipt
    WHERE (p_after_id IS NULL OR (receipt.sold_at,receipt.receipt_id)<(p_after_at,p_after_id))
      AND (v_status IS NULL OR receipt.receipt_status = v_status)
      AND (
        v_query IS NULL
        OR receipt.receipt_number ILIKE '%' || v_query || '%'
        OR receipt.store_name ILIKE '%' || v_query || '%'
        OR receipt.table_number ILIKE '%' || v_query || '%'
        OR COALESCE(receipt.order_id::text, '') ILIKE '%' || v_query || '%'
        OR COALESCE(receipt.combined_payment_group_id::text, '')
          ILIKE '%' || v_query || '%'
        OR receipt.order_ids::text ILIKE '%' || v_query || '%'
        OR receipt.allocations::text ILIKE '%' || v_query || '%'
      )
  ),
  page AS (
    SELECT *
    FROM filtered_receipts
    ORDER BY sold_at DESC, receipt_id DESC
    LIMIT v_limit OFFSET v_offset
  ),
  pos_order_keys AS (
    SELECT DISTINCT
      payment.ledger_key,
      payment.combined_payment_group_id,
      payment.order_id,
      payment.store_id
    FROM scoped_payments payment
    JOIN page selected ON selected.receipt_source='pos' AND payment.ledger_key = CASE
      WHEN selected.combined_payment_group_id IS NULL THEN 'order:'||selected.order_id::text
      ELSE 'combined:'||selected.combined_payment_group_id::text END
  ),
  pos_order_items AS (
    SELECT
      order_key.ledger_key,
      jsonb_agg(jsonb_build_object(
        'order_id', item.order_id,
        'table_number', COALESCE(table_row.table_number, 'TAKEAWAY'),
        'name', CASE
          WHEN order_key.combined_payment_group_id IS NULL THEN COALESCE(
            NULLIF(item.display_name, ''), NULLIF(item.label, ''), 'Item'
          )
          ELSE '[' || COALESCE(table_row.table_number, 'TAKEAWAY') || '] ' ||
            COALESCE(
              NULLIF(item.display_name, ''), NULLIF(item.label, ''), 'Item'
            )
        END,
        'name_ko', CASE WHEN NULLIF(btrim(menu_item.name_ko), '') IS NOT NULL THEN
          CASE WHEN order_key.combined_payment_group_id IS NULL THEN ''
            ELSE '[' || COALESCE(table_row.table_number, 'TAKEAWAY') || '] ' END
          || menu_item.name_ko END,
        'name_vi', CASE WHEN NULLIF(btrim(menu_item.name_vi), '') IS NOT NULL THEN
          CASE WHEN order_key.combined_payment_group_id IS NULL THEN ''
            ELSE '[' || COALESCE(table_row.table_number, 'TAKEAWAY') || '] ' END
          || menu_item.name_vi END,
        'name_en', CASE WHEN NULLIF(btrim(menu_item.name_en), '') IS NOT NULL THEN
          CASE WHEN order_key.combined_payment_group_id IS NULL THEN ''
            ELSE '[' || COALESCE(table_row.table_number, 'TAKEAWAY') || '] ' END
          || menu_item.name_en END,
        'quantity', item.quantity,
        'unit_price', item.unit_price
      ) ORDER BY
        COALESCE(table_row.table_number, 'TAKEAWAY'),
        item.created_at,
        item.id
      ) AS items
    FROM pos_order_keys order_key
    JOIN public.orders order_row ON order_row.id = order_key.order_id
    LEFT JOIN public.tables table_row ON table_row.id = order_row.table_id
    JOIN public.order_items item ON item.order_id = order_key.order_id
    LEFT JOIN public.menu_items menu_item
      ON menu_item.id = COALESCE(item.menu_item_id_snapshot, item.menu_item_id)
      AND menu_item.restaurant_id = item.restaurant_id
    WHERE item.status <> 'cancelled'
    GROUP BY order_key.ledger_key
  ),
  summary AS (
    SELECT
      count(*)::integer AS receipt_count,
      ROUND(COALESCE(sum(gross_amount), 0), 2) AS gross_amount,
      ROUND(COALESCE(sum(adjusted_amount), 0), 2) AS adjusted_amount,
      ROUND(COALESCE(sum(net_amount), 0), 2) AS net_amount
    FROM all_receipts WHERE p_include_summary
  )
  SELECT jsonb_build_object(
    'business_date', v_business_date,
    'generated_at', statement_timestamp(),
    'summary', CASE WHEN p_include_summary THEN jsonb_build_object(
      'receipt_count', summary.receipt_count,
      'gross_amount', summary.gross_amount,
      'adjusted_amount', summary.adjusted_amount,
      'net_amount', summary.net_amount
    ) ELSE NULL END,
    'receipts', COALESCE(
      (SELECT jsonb_agg(to_jsonb(page)||jsonb_build_object('items',COALESCE(detail.items,'[]'::jsonb)) ORDER BY page.sold_at DESC,page.receipt_id DESC)
         FROM page LEFT JOIN pos_order_items detail ON detail.ledger_key=CASE
           WHEN page.combined_payment_group_id IS NULL THEN 'order:'||page.order_id::text
           ELSE 'combined:'||page.combined_payment_group_id::text END),
      '[]'::jsonb
    ),
    'has_more',
      EXISTS (SELECT 1 FROM filtered_receipts OFFSET v_offset + v_limit LIMIT 1)
  ) INTO v_result
  FROM summary;

  RETURN v_result;
END;
$$;
REVOKE ALL ON FUNCTION public.get_receipt_ledger_page(date,uuid,text,text,integer,integer,timestamptz,text,boolean) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_receipt_ledger_page(date,uuid,text,text,integer,integer,timestamptz,text,boolean) TO authenticated;

-- COMPONENT 20261011060000_emergency_push_batch_lease.sql SHA256 7467bfcb26eb625b23784af22138beadb8fc9d14387630113298abc9696f06a7

ALTER TABLE public.emergency_push_deliveries ADD COLUMN IF NOT EXISTS claim_id uuid,
  ADD COLUMN IF NOT EXISTS claim_expires_at timestamptz;
CREATE OR REPLACE FUNCTION public.claim_emergency_push_batch(p_claim_id uuid, p_limit integer DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public,auth,pg_catalog AS $$
DECLARE v_rows jsonb;v_more boolean;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'EMERGENCY_PUSH_SERVICE_REQUIRED'; END IF;
  IF p_claim_id IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION 'EMERGENCY_PUSH_BATCH_INVALID'; END IF;
  WITH candidate AS MATERIALIZED (
    SELECT id,created_at FROM public.emergency_push_deliveries WHERE
      ((status IN ('pending','failed') AND next_attempt_at<=now()) OR (status='sending' AND claim_expires_at<now()))
      AND attempt_count<10 ORDER BY created_at,id LIMIT p_limit+1 FOR UPDATE SKIP LOCKED
  ), selected AS (SELECT id FROM candidate ORDER BY created_at,id LIMIT p_limit), updated AS (
    UPDATE public.emergency_push_deliveries d SET status='sending',claim_id=p_claim_id,
    claim_expires_at=now()+interval '90 seconds',attempt_count=d.attempt_count+1,updated_at=now()
    FROM selected c WHERE c.id=d.id RETURNING d.*
  ) SELECT COALESCE(jsonb_agg(to_jsonb(updated) ORDER BY created_at,id),'[]'),(SELECT count(*) FROM candidate)>p_limit
    INTO v_rows,v_more FROM updated;
  RETURN jsonb_build_object('rows',v_rows,'has_more',v_more);
END $$;
CREATE OR REPLACE FUNCTION public.complete_emergency_push_batch(p_claim_id uuid,p_results jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public,auth,pg_catalog AS $$
DECLARE v_count integer;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'EMERGENCY_PUSH_SERVICE_REQUIRED'; END IF;
  IF p_claim_id IS NULL OR jsonb_typeof(p_results) IS DISTINCT FROM 'array' OR jsonb_array_length(p_results)>50
    OR (SELECT count(DISTINCT r->>'id') FROM jsonb_array_elements(p_results) r)<>jsonb_array_length(p_results)
    THEN RAISE EXCEPTION 'EMERGENCY_PUSH_BATCH_INVALID'; END IF;
  WITH result AS (SELECT * FROM jsonb_to_recordset(p_results) AS r(id uuid,accepted boolean,
    permanent boolean,deferred boolean,provider_message_id text,error text,retry_seconds integer)),
  updated AS (
    UPDATE public.emergency_push_deliveries d SET status=CASE WHEN r.accepted THEN 'sent'
      WHEN r.permanent THEN 'cancelled' WHEN r.deferred THEN 'pending' ELSE 'failed' END,
      attempt_count=d.attempt_count-CASE WHEN r.deferred THEN 1 ELSE 0 END,
      provider_message_id=r.provider_message_id,last_error=left(r.error,1000),
      next_attempt_at=now()+make_interval(secs=>LEAST(GREATEST(COALESCE(r.retry_seconds,30),5),3600)),
      claim_id=NULL,claim_expires_at=NULL,updated_at=now()
    FROM result r WHERE d.id=r.id AND d.claim_id=p_claim_id AND d.status='sending'
      AND d.claim_expires_at>now() RETURNING d.device_id,d.push_token,r.permanent,r.error
  ), disabled AS (
    UPDATE public.emergency_web_push_devices device SET is_enabled=false,updated_at=now()
    FROM updated u WHERE u.permanent AND u.error='FCM_UNREGISTERED' AND device.id=u.device_id AND device.token=u.push_token RETURNING device.id
  ) SELECT count(*) INTO v_count FROM updated;
  RETURN v_count;
END $$;
-- During a rolling deployment, a legacy worker must not finish a new owned claim.
CREATE OR REPLACE FUNCTION public.complete_emergency_push_delivery(
  p_delivery_id uuid,
  p_accepted boolean,
  p_provider_message_id text DEFAULT NULL,
  p_error text DEFAULT NULL,
  p_retry_after_seconds integer DEFAULT 30
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'EMERGENCY_PUSH_SERVICE_REQUIRED';
  END IF;
  UPDATE public.emergency_push_deliveries
  SET status = CASE WHEN p_accepted THEN 'sent' ELSE 'failed' END,
      provider_message_id = p_provider_message_id,
      last_error = CASE WHEN p_accepted THEN NULL ELSE p_error END,
      next_attempt_at = CASE WHEN p_accepted THEN next_attempt_at
        ELSE now() + make_interval(secs => LEAST(
          GREATEST(COALESCE(p_retry_after_seconds, 30), 5), 3600
        )) END,
      updated_at = now()
  WHERE id = p_delivery_id AND claim_id IS NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.claim_emergency_push_batch(uuid,integer),public.complete_emergency_push_batch(uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_emergency_push_batch(uuid,integer),public.complete_emergency_push_batch(uuid,jsonb) TO service_role;

-- COMPONENT 20261011070000_inventory_dashboard_shared_stock.sql SHA256 1d56f86fe2656b2e5dbc200885e64f7b380c2c3ca33fb23da74cd1facecf9263

CREATE OR REPLACE FUNCTION public.get_inventory_purchase_dashboard_v2(
  p_store_id UUID DEFAULT NULL,
  p_brand_id UUID DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_scope_store_ids UUID[];
  v_total_inventory_amount NUMERIC(12,2);
  v_submitted_purchase_amount NUMERIC(12,2);
  v_approved_purchase_amount NUMERIC(12,2);
BEGIN
  SELECT ARRAY_AGG(r.id)
  INTO v_scope_store_ids
  FROM public.restaurants r
  WHERE (p_store_id IS NULL OR r.id = p_store_id)
    AND (p_brand_id IS NULL OR r.brand_id = p_brand_id)
    AND public.can_access_inventory_purchase_store(r.id);

  IF v_scope_store_ids IS NULL OR array_length(v_scope_store_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  SELECT COALESCE(SUM(COALESCE(ii.current_stock, 0) * COALESCE(ii.cost_per_unit, 0)), 0)
  INTO v_total_inventory_amount
  FROM public.inventory_products ip
  LEFT JOIN public.inventory_items ii
    ON ii.id = ip.inventory_item_id
   AND ii.restaurant_id = ip.restaurant_id
  WHERE ip.restaurant_id = ANY(v_scope_store_ids)
    AND ip.is_active = TRUE;

  SELECT COALESCE(SUM(total_amount) FILTER (WHERE status = 'submitted'), 0),
         COALESCE(SUM(total_amount) FILTER (WHERE status = 'office_approved'), 0)
  INTO v_submitted_purchase_amount, v_approved_purchase_amount
  FROM public.inventory_purchase_orders
  WHERE restaurant_id = ANY(v_scope_store_ids) AND status IN ('submitted','office_approved');

  -- Low stock is composed from the shared stock-status read by InventoryService.

  RETURN jsonb_build_object(
    'store_count', array_length(v_scope_store_ids, 1),
    'total_inventory_amount', v_total_inventory_amount,
    'submitted_purchase_amount', v_submitted_purchase_amount,
    'approved_purchase_amount', v_approved_purchase_amount
  );
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth;
REVOKE ALL ON FUNCTION public.get_inventory_purchase_dashboard_v2(uuid,uuid) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_inventory_purchase_dashboard_v2(uuid,uuid) TO authenticated;

-- COMPONENT 20261011080000_meinvoice_owned_batches.sql SHA256 bffe59d32d2f6f38250a305b433bbb0721130eaf97a58aa8b8d38507bd3d3623

-- Does not enable or schedule MISA. A publish with an uncertain outcome is
-- parked for portal reconciliation; it is never silently published again.
ALTER TABLE public.meinvoice_jobs ADD COLUMN IF NOT EXISTS dispatch_claim_id uuid,
  ADD COLUMN IF NOT EXISTS dispatch_claim_expires_at timestamptz;
CREATE TABLE IF NOT EXISTS public.meinvoice_token_refresh_leases(
  tax_entity_id uuid PRIMARY KEY REFERENCES public.tax_entity(id),
  owner_id uuid NOT NULL, expires_at timestamptz NOT NULL
);
ALTER TABLE public.meinvoice_token_refresh_leases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.meinvoice_token_refresh_leases FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.meinvoice_token_refresh_leases TO service_role;
CREATE OR REPLACE FUNCTION public.claim_meinvoice_jobs(p_claim_id uuid,p_limit integer DEFAULT 50,p_tax_entity_id uuid DEFAULT NULL)
RETURNS SETOF public.meinvoice_jobs LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'MEINVOICE_SERVICE_REQUIRED'; END IF;
  IF p_claim_id IS NULL OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION 'MEINVOICE_BATCH_INVALID'; END IF;
  -- A worker may have sent a publish before crashing. Preserve evidence and
  -- require operator/provider reconciliation instead of reclaiming this write.
  WITH expired AS (
    UPDATE public.meinvoice_jobs SET status='manual_action_required',manual_action_type='misa_portal_review',
      error_message='DISPATCH_OUTCOME_UNKNOWN',dispatch_claim_id=NULL,dispatch_claim_expires_at=NULL,updated_at=now()
    WHERE status='pending' AND dispatch_claim_expires_at<now() RETURNING id,dispatch_attempts
  ) INSERT INTO public.meinvoice_job_events(job_id,event_type,description,retry_count)
    SELECT id,'dispatch_outcome_unknown','Expired publish ownership requires portal reconciliation',dispatch_attempts FROM expired;
  RETURN QUERY WITH candidate AS (
    SELECT id FROM public.meinvoice_jobs WHERE status='pending' AND dispatch_claim_id IS NULL
      AND (p_tax_entity_id IS NULL OR tax_entity_id=p_tax_entity_id)
      ORDER BY created_at,id LIMIT p_limit FOR UPDATE SKIP LOCKED
  ) UPDATE public.meinvoice_jobs j SET dispatch_claim_id=p_claim_id,dispatch_claim_expires_at=now()+interval '90 seconds',
    dispatch_attempts=j.dispatch_attempts+1,last_dispatch_at=now(),updated_at=now()
    FROM candidate c WHERE j.id=c.id RETURNING j.*;
END $$;
CREATE OR REPLACE FUNCTION public.complete_meinvoice_batch(p_claim_id uuid,p_results jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v_count integer;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'MEINVOICE_SERVICE_REQUIRED'; END IF;
  IF p_claim_id IS NULL OR jsonb_typeof(p_results) IS DISTINCT FROM 'array' OR jsonb_array_length(p_results)>50
    OR (SELECT count(DISTINCT r->>'id') FROM jsonb_array_elements(p_results) r)<>jsonb_array_length(p_results)
    OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_results) r WHERE r->>'status' NOT IN
      ('pending','dispatch_paused','failed','valid_invoice','manual_action_required')) THEN RAISE EXCEPTION 'MEINVOICE_BATCH_INVALID'; END IF;
  WITH result AS (SELECT * FROM jsonb_to_recordset(p_results) r(id uuid,status text,error_message text,
    misa_ref_id text,transaction_id text,invoice_series text,invoice_number text,tax_authority_code text,
    search_code text,event_type text,metadata jsonb)), updated AS (
    UPDATE public.meinvoice_jobs j SET status=r.status,
      dispatch_attempts=j.dispatch_attempts-CASE WHEN r.status='pending' THEN 1 ELSE 0 END,
      error_message=left(r.error_message,1000),
      misa_ref_id=COALESCE(r.misa_ref_id,j.misa_ref_id),transaction_id=COALESCE(r.transaction_id,j.transaction_id),
      invoice_series=COALESCE(r.invoice_series,j.invoice_series),invoice_number=COALESCE(r.invoice_number,j.invoice_number),
      tax_authority_code=COALESCE(r.tax_authority_code,j.tax_authority_code),search_code=COALESCE(r.search_code,j.search_code),
      manual_action_type=CASE WHEN r.status='manual_action_required' THEN 'misa_portal_review' ELSE j.manual_action_type END,
      sent_at=CASE WHEN r.status='valid_invoice' THEN now() ELSE j.sent_at END,
      dispatch_claim_id=NULL,dispatch_claim_expires_at=NULL,updated_at=now()
    FROM result r WHERE j.id=r.id AND j.dispatch_claim_id=p_claim_id AND j.dispatch_claim_expires_at>now() AND j.status='pending'
      RETURNING j.id,j.dispatch_attempts,r.event_type,r.error_message,r.metadata
  ), logged AS (
    INSERT INTO public.meinvoice_job_events(job_id,event_type,description,retry_count,metadata)
    SELECT id,COALESCE(event_type,'dispatch_completed'),left(error_message,1000),dispatch_attempts,COALESCE(metadata,'{}') FROM updated RETURNING id
  ) SELECT count(*) INTO v_count FROM updated;
  RETURN v_count;
END $$;
CREATE OR REPLACE FUNCTION public.claim_meinvoice_token_refresh(p_tax_entity_id uuid,p_owner_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v_id uuid;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'MEINVOICE_SERVICE_REQUIRED'; END IF;
  INSERT INTO public.meinvoice_token_refresh_leases VALUES(p_tax_entity_id,p_owner_id,now()+interval '30 seconds')
  ON CONFLICT(tax_entity_id) DO UPDATE SET owner_id=EXCLUDED.owner_id,expires_at=EXCLUDED.expires_at
    WHERE meinvoice_token_refresh_leases.expires_at<now() RETURNING tax_entity_id INTO v_id;
  RETURN v_id IS NOT NULL;
END $$;
REVOKE ALL ON FUNCTION public.claim_meinvoice_jobs(uuid,integer,uuid),public.complete_meinvoice_batch(uuid,jsonb),public.claim_meinvoice_token_refresh(uuid,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_meinvoice_jobs(uuid,integer,uuid),public.complete_meinvoice_batch(uuid,jsonb),public.claim_meinvoice_token_refresh(uuid,uuid) TO service_role;

-- COMPONENT 20261011090000_sepay_delivery_provider_scope.sql SHA256 e863b28cd4632966d0a1fc90ec6fd075033cb06906ecc785bd22d385c6206ab7

CREATE OR REPLACE FUNCTION public.ingest_sepay_transaction_with_delivery_scope(
  p_sepay_transaction_id bigint,
  p_gateway text,
  p_account_number text,
  p_sub_account text,
  p_transfer_type text,
  p_transfer_amount bigint,
  p_payment_code text,
  p_reference_code text,
  p_transaction_at timestamptz,
  p_raw_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_number text := regexp_replace(
    COALESCE(p_account_number, ''),
    '[^a-zA-Z0-9]',
    '',
    'g'
  );
  v_sub_account text := NULLIF(
    regexp_replace(COALESCE(p_sub_account, ''), '[^a-zA-Z0-9]', '', 'g'),
    ''
  );
  v_candidate_count integer := 0;
  v_mapping_id uuid;
  v_mapping public.sepay_bank_accounts%ROWTYPE;
  v_transaction public.sepay_transactions%ROWTYPE;
BEGIN
  IF p_sepay_transaction_id IS NULL
     OR btrim(COALESCE(p_gateway, '')) = ''
     OR v_account_number = ''
     OR p_transfer_type NOT IN ('in', 'out')
     OR COALESCE(p_transfer_amount, 0) <= 0
     OR p_raw_payload IS NULL THEN
    RAISE EXCEPTION 'SEPAY_TRANSACTION_INVALID';
  END IF;

  SELECT count(*), (array_agg(mapping.id))[1]
  INTO v_candidate_count, v_mapping_id
  FROM public.sepay_bank_accounts mapping
  WHERE mapping.is_active = true
    AND lower(btrim(mapping.gateway)) = lower(btrim(p_gateway))
    AND regexp_replace(
      mapping.account_number,
      '[^a-zA-Z0-9]',
      '',
      'g'
    ) = v_account_number
    AND COALESCE(
      NULLIF(
        regexp_replace(
          COALESCE(mapping.sub_account, ''),
          '[^a-zA-Z0-9]',
          '',
          'g'
        ),
        ''
      ),
      ''
    ) = COALESCE(v_sub_account, '');

  IF v_candidate_count = 1 THEN
    SELECT * INTO v_mapping
    FROM public.sepay_bank_accounts
    WHERE id = v_mapping_id;
  END IF;

  INSERT INTO public.sepay_transactions (
    sepay_transaction_id,
    restaurant_id,
    sepay_bank_account_id,
    gateway,
    account_number,
    sub_account,
    transfer_type,
    transfer_amount,
    payment_code,
    reference_code,
    transaction_at,
    resolution_status,
    raw_payload
  ) VALUES (
    p_sepay_transaction_id,
    CASE WHEN v_candidate_count = 1 THEN v_mapping.restaurant_id END,
    CASE WHEN v_candidate_count = 1 THEN v_mapping.id END,
    btrim(p_gateway),
    v_account_number,
    v_sub_account,
    p_transfer_type,
    p_transfer_amount,
    NULLIF(btrim(COALESCE(p_payment_code, '')), ''),
    NULLIF(btrim(COALESCE(p_reference_code, '')), ''),
    p_transaction_at,
    CASE
      WHEN v_candidate_count = 1 THEN 'matched'
      WHEN v_candidate_count = 0 THEN 'unmatched'
      ELSE 'ambiguous'
    END,
    p_raw_payload
  )
  ON CONFLICT (sepay_transaction_id) DO NOTHING
  RETURNING * INTO v_transaction;

  IF v_transaction.id IS NULL THEN
    SELECT * INTO v_transaction
    FROM public.sepay_transactions
    WHERE sepay_transaction_id = p_sepay_transaction_id;

    RETURN jsonb_build_object(
      'status', 'duplicate',
      'transaction_id', v_transaction.id,
      'restaurant_id', v_transaction.restaurant_id,
      'resolution_status', v_transaction.resolution_status
    );
  END IF;

  RETURN jsonb_build_object(
    'status', 'accepted',
    'push_dispatch_required', EXISTS (
      SELECT 1 FROM public.sepay_alert_deliveries d JOIN public.sepay_alert_devices device ON device.id=d.device_id
      WHERE d.transaction_id=v_transaction.id AND d.status IN ('queued','failed')
        AND device.is_enabled AND device.push_provider='fcm'
    ),
    'transaction_id', v_transaction.id,
    'restaurant_id', v_transaction.restaurant_id,
    'resolution_status', v_transaction.resolution_status
  );
END;
$$;
REVOKE ALL ON FUNCTION public.ingest_sepay_transaction_with_delivery_scope(bigint,text,text,text,text,bigint,text,text,timestamptz,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.ingest_sepay_transaction_with_delivery_scope(bigint,text,text,text,text,bigint,text,text,timestamptz,jsonb) TO service_role;

-- COMPONENT 20261011100000_inventory_catalog_pages.sql SHA256 f6216eaf55040a45738e7cb2e11ce0f9a35207bdf811fb498b6c093f111a1869

CREATE OR REPLACE FUNCTION public.get_inventory_catalog_page(
  p_store_id uuid,p_source text,p_query text DEFAULT NULL,p_supplier_id uuid DEFAULT NULL,
  p_product_id uuid DEFAULT NULL,p_after_id uuid DEFAULT NULL,p_limit integer DEFAULT 50
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=public,auth,pg_catalog AS $$
DECLARE v_rows jsonb; v_more boolean; v_stats jsonb; v_query text:=NULLIF(btrim(p_query),'');
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_read_inventory_purchase_store(p_store_id) THEN RAISE EXCEPTION 'INVENTORY_PURCHASE_CATALOG_FORBIDDEN'; END IF;
  IF p_source IS NULL OR p_source NOT IN ('products','supplier_items','ingredient_export') OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 500
    OR length(COALESCE(v_query,''))>100 THEN RAISE EXCEPTION 'INVENTORY_CATALOG_QUERY_INVALID'; END IF;
  IF p_source IN ('products','ingredient_export') THEN
    SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.id),'[]') INTO v_rows FROM (
      SELECT p.id,p.restaurant_id,p.brand_id,p.inventory_item_id,p.product_code,p.name,p.category,
        p.stock_unit,p.base_unit,p.base_unit_factor,p.image_url,p.storage_type,p.shelf_life_days,
        p.is_orderable,p.is_active,p.created_at,p.updated_at,
        CASE WHEN p_source='ingredient_export' THEN (
          SELECT jsonb_build_object('supplier_name',s.supplier_name,'unit_price',link.unit_price)
          FROM public.inventory_supplier_items link JOIN public.inventory_suppliers s ON s.id=link.supplier_id
          WHERE link.product_id=p.id AND link.is_active AND s.status='active'
          ORDER BY link.is_preferred DESC,link.updated_at DESC,link.id LIMIT 1
        ) ELSE NULL END AS export_supplier,
        CASE WHEN i.id IS NULL THEN NULL ELSE jsonb_build_object('current_stock',i.current_stock,'reorder_point',i.reorder_point,'cost_per_unit',i.cost_per_unit,'supplier_name',i.supplier_name) END AS inventory_item
      FROM public.inventory_products p LEFT JOIN public.inventory_items i ON i.id=p.inventory_item_id AND i.restaurant_id=p.restaurant_id
      WHERE p.restaurant_id=p_store_id AND (p_after_id IS NULL OR p.id>p_after_id)
        AND (v_query IS NULL OR p.name ILIKE '%'||v_query||'%' OR p.product_code ILIKE '%'||v_query||'%')
      ORDER BY p.id LIMIT p_limit+1
    )q;
    IF p_after_id IS NULL AND p_source='products' THEN
      SELECT jsonb_build_object('total',count(*),'active',count(*) FILTER(WHERE is_active),'orderable',count(*) FILTER(WHERE is_orderable),'supplier_links',(SELECT count(*) FROM public.inventory_supplier_items link JOIN public.inventory_products scoped ON scoped.id=link.product_id WHERE scoped.restaurant_id=p_store_id)) INTO v_stats
      FROM public.inventory_products p WHERE p.restaurant_id=p_store_id
        AND (v_query IS NULL OR p.name ILIKE '%'||v_query||'%' OR p.product_code ILIKE '%'||v_query||'%');
    END IF;
  ELSE
    SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.id),'[]') INTO v_rows FROM (
      SELECT i.id,i.supplier_id,i.product_id,i.supplier_sku,i.order_unit,i.order_unit_quantity_base,
        i.min_order_quantity,i.unit_price,i.tax_rate,i.lead_time_days,i.is_preferred,i.is_active,i.created_at,i.updated_at,
        jsonb_build_object('id',s.id,'supplier_name',s.supplier_name,'status',s.status) AS supplier,
        jsonb_build_object('id',p.id,'restaurant_id',p.restaurant_id,'name',p.name,'product_code',p.product_code,
          'category',p.category,'stock_unit',p.stock_unit,'base_unit',p.base_unit,'base_unit_factor',p.base_unit_factor,
          'is_orderable',p.is_orderable,'is_active',p.is_active) AS product
      FROM public.inventory_supplier_items i JOIN public.inventory_products p ON p.id=i.product_id
      JOIN public.inventory_suppliers s ON s.id=i.supplier_id
      WHERE p.restaurant_id=p_store_id AND (p_after_id IS NULL OR i.id>p_after_id)
        AND (p_supplier_id IS NULL OR i.supplier_id=p_supplier_id) AND (p_product_id IS NULL OR i.product_id=p_product_id)
        AND (v_query IS NULL OR p.name ILIKE '%'||v_query||'%' OR i.supplier_sku ILIKE '%'||v_query||'%')
      ORDER BY i.id LIMIT p_limit+1
    )q;
    IF p_after_id IS NULL THEN
      SELECT jsonb_build_object('total',count(*)) INTO v_stats FROM public.inventory_supplier_items i
      JOIN public.inventory_products p ON p.id=i.product_id JOIN public.inventory_suppliers s ON s.id=i.supplier_id
      WHERE p.restaurant_id=p_store_id AND (p_supplier_id IS NULL OR i.supplier_id=p_supplier_id)
        AND (p_product_id IS NULL OR i.product_id=p_product_id)
        AND (v_query IS NULL OR p.name ILIKE '%'||v_query||'%' OR i.supplier_sku ILIKE '%'||v_query||'%');
    END IF;
  END IF;
  v_more:=jsonb_array_length(v_rows)>p_limit;
  IF v_more THEN v_rows:=v_rows-p_limit; END IF;
  RETURN jsonb_build_object('version',1,'rows',v_rows,'has_more',v_more,'stats',v_stats);
END $$;
REVOKE ALL ON FUNCTION public.get_inventory_catalog_page(uuid,text,text,uuid,uuid,uuid,integer) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_inventory_catalog_page(uuid,text,text,uuid,uuid,uuid,integer) TO authenticated;

-- COMPONENT 20261011110000_table_preview_delta.sql SHA256 41aa8b0eff07c48055894698dfd2f20bd962e4efba92393c933d7ccf3fd1c5a5

CREATE OR REPLACE FUNCTION public.get_table_order_previews_delta(p_store_id uuid,p_order_ids uuid[],p_table_ids uuid[] DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY INVOKER SET search_path=public,auth,pg_catalog AS $$
DECLARE v_rows jsonb;
BEGIN
 IF auth.uid() IS NULL OR p_store_id IS NULL OR COALESCE(cardinality(p_order_ids),0) NOT BETWEEN 1 AND 50
   OR p_table_ids IS NULL OR cardinality(p_table_ids)>50 OR array_position(p_order_ids,NULL) IS NOT NULL
   OR array_position(p_table_ids,NULL) IS NOT NULL THEN RAISE EXCEPTION 'TABLE_PREVIEW_QUERY_INVALID'; END IF;
 WITH affected AS MATERIALIZED (
   SELECT table_id FROM public.orders WHERE restaurant_id=p_store_id AND id=ANY(p_order_ids) AND table_id IS NOT NULL
   UNION SELECT id FROM public.tables WHERE restaurant_id=p_store_id AND id=ANY(p_table_ids)
 ), selected AS MATERIALIZED (
   SELECT DISTINCT ON(o.table_id) o.id,o.table_id,o.created_at FROM public.orders o JOIN affected a ON a.table_id=o.table_id
   WHERE o.restaurant_id=p_store_id AND o.status NOT IN ('completed','cancelled') ORDER BY o.table_id,o.created_at DESC,o.id DESC
 ), items AS (
   SELECT i.order_id,jsonb_agg(jsonb_build_object('id',i.id,'created_at',i.created_at,'label',i.label,
    'quantity',i.quantity,'status',i.status,'menu_items',jsonb_build_object('name',m.name,'name_ko',m.name_ko,'name_vi',m.name_vi,'name_en',m.name_en))
    ORDER BY i.created_at,i.id) rows FROM selected s JOIN public.order_items i ON i.order_id=s.id
    LEFT JOIN public.menu_items m ON m.id=i.menu_item_id WHERE i.status IS DISTINCT FROM 'cancelled' GROUP BY i.order_id
 ) SELECT coalesce(jsonb_agg(jsonb_build_object('table_id',a.table_id,'id',s.id,'created_at',s.created_at,'order_items',coalesce(i.rows,'[]')) ORDER BY a.table_id),'[]')
 INTO v_rows FROM affected a LEFT JOIN selected s ON s.table_id=a.table_id LEFT JOIN items i ON i.order_id=s.id;
 RETURN jsonb_build_object('version',1,'rows',v_rows);
END $$;
REVOKE ALL ON FUNCTION public.get_table_order_previews_delta(uuid,uuid[],uuid[]) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.get_table_order_previews_delta(uuid,uuid[],uuid[]) TO authenticated;

-- COMPONENT 20261011120000_recipe_export_pages.sql SHA256 d866c6d7b17e502f3edcfda3353d0de39fd4d9868611753f1a4936b33995352b

CREATE INDEX IF NOT EXISTS menu_recipes_store_export_id_idx ON public.menu_recipes(restaurant_id,id);
CREATE INDEX IF NOT EXISTS menu_items_store_export_id_idx ON public.menu_items(restaurant_id,id);
CREATE INDEX IF NOT EXISTS inventory_products_store_export_id_idx ON public.inventory_products(restaurant_id,id);
-- Preserve the recipe catalog's explicit store-access boundary while exporting
-- flat, bounded pages. Both joins below are many-to-one primary-key joins.
CREATE OR REPLACE FUNCTION public.get_inventory_recipe_export_page(
  p_store_id uuid, p_source text, p_after_id uuid DEFAULT NULL,
  p_limit integer DEFAULT 500
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path=public,auth,pg_catalog AS $$
DECLARE v_rows jsonb; v_more boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_FORBIDDEN';
  END IF;
  IF p_source IS NULL OR p_source NOT IN ('recipes','menus','ingredients')
    OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_EXPORT_QUERY_INVALID';
  END IF;
  IF p_source='recipes' THEN
    SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.id),'[]') INTO v_rows FROM (
      SELECT r.id,r.restaurant_id,m.name AS menu_item_name,
        i.name AS ingredient_name,r.quantity_g
      FROM public.menu_recipes r
      JOIN public.menu_items m ON m.id=r.menu_item_id AND m.restaurant_id=r.restaurant_id
      JOIN public.inventory_items i ON i.id=r.ingredient_id AND i.restaurant_id=r.restaurant_id
      WHERE r.restaurant_id=p_store_id AND (p_after_id IS NULL OR r.id>p_after_id)
      ORDER BY r.id LIMIT p_limit+1
    )q;
  ELSIF p_source='menus' THEN
    SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.id),'[]') INTO v_rows FROM (
      SELECT m.id,m.restaurant_id,m.name FROM public.menu_items m
      WHERE m.restaurant_id=p_store_id AND (p_after_id IS NULL OR m.id>p_after_id)
        AND NULLIF(btrim(m.name),'') IS NOT NULL
      ORDER BY m.id LIMIT p_limit+1
    )q;
  ELSE
    SELECT COALESCE(jsonb_agg(to_jsonb(q) ORDER BY q.id),'[]') INTO v_rows FROM (
      SELECT p.id,p.restaurant_id,p.name,p.base_unit FROM public.inventory_products p
      WHERE p.restaurant_id=p_store_id AND (p_after_id IS NULL OR p.id>p_after_id)
        AND p.inventory_item_id IS NOT NULL AND p.is_active
        AND lower(p.base_unit) IN ('g','ml','ea')
      ORDER BY p.id LIMIT p_limit+1
    )q;
  END IF;
  v_more:=jsonb_array_length(v_rows)>p_limit;
  IF v_more THEN v_rows:=v_rows-p_limit; END IF;
  RETURN jsonb_build_object('version',1,'rows',v_rows,'has_more',v_more);
END $$;
REVOKE ALL ON FUNCTION public.get_inventory_recipe_export_page(uuid,text,uuid,integer)
  FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_inventory_recipe_export_page(uuid,text,uuid,integer)
  TO authenticated;

-- COMPONENT 20261011130000_company_tax_lookup.sql SHA256 2f3858b0a9c04fe7742a0556025405626a16a2eb7f392edb849d29eaa4531a8d
-- Public company names only; no buyer/contact cache or payment/invoice mutation.
-- production-gate: self-verifying

SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';

CREATE TABLE public.company_tax_lookup_settings (
  store_id uuid PRIMARY KEY REFERENCES public.restaurants(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT false
);
CREATE TABLE public.company_tax_lookup_rate (
  actor_id uuid PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  window_start timestamptz NOT NULL,
  used integer NOT NULL CHECK (used BETWEEN 0 AND 10)
);
CREATE TABLE public.company_tax_lookup_slots (
  slot smallint PRIMARY KEY CHECK (slot BETWEEN 1 AND 2),
  lease_id uuid,
  auth_user_id uuid,
  lease_until timestamptz NOT NULL DEFAULT '-infinity'
);
INSERT INTO public.company_tax_lookup_slots(slot) VALUES (1), (2);
ALTER TABLE public.company_tax_lookup_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_tax_lookup_rate ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_tax_lookup_slots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.company_tax_lookup_settings, public.company_tax_lookup_rate,
  public.company_tax_lookup_slots FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.company_tax_lookup_settings, public.company_tax_lookup_rate,
  public.company_tax_lookup_slots TO service_role;

-- Only Edge's verified Auth user id is accepted; browsers cannot claim leases.
CREATE FUNCTION public.pos_claim_company_tax_lookup(p_auth_user_id uuid, p_store_id uuid, p_lease_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor_id uuid; v_actor_role text; bucket public.company_tax_lookup_rate%ROWTYPE;
  available_slot smallint; checked_at timestamptz;
BEGIN
  SELECT u.id, u.role INTO v_actor_id, v_actor_role FROM public.users u
    WHERE u.auth_id = $1 AND u.is_active LIMIT 1;
  IF v_actor_id IS NULL OR v_actor_role IS NULL OR v_actor_role NOT IN ('cashier','admin','store_admin','brand_admin','super_admin')
    OR NOT EXISTS (SELECT 1 FROM public.restaurants WHERE id = $2 AND is_active)
    OR v_actor_role <> 'super_admin' AND NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores($1) scope(store_id) WHERE scope.store_id = $2
    ) THEN RETURN jsonb_build_object('outcome','forbidden'); END IF;
  IF $3 IS NULL THEN RETURN jsonb_build_object('outcome','forbidden'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.company_tax_lookup_settings WHERE store_id = $2 AND enabled)
    THEN RETURN jsonb_build_object('outcome','disabled'); END IF;
  INSERT INTO public.company_tax_lookup_rate(actor_id,window_start,used)
    VALUES (v_actor_id,clock_timestamp(),0) ON CONFLICT ON CONSTRAINT company_tax_lookup_rate_pkey DO NOTHING;
  SELECT * INTO bucket FROM public.company_tax_lookup_rate r WHERE r.actor_id = v_actor_id FOR UPDATE;
  checked_at := clock_timestamp();
  IF checked_at >= bucket.window_start + interval '60 seconds' THEN bucket.used := 0; bucket.window_start := checked_at; END IF;
  IF bucket.used >= 10 THEN RETURN jsonb_build_object('outcome','rate_limited'); END IF;
  SELECT slot INTO available_slot FROM public.company_tax_lookup_slots
    WHERE lease_until <= checked_at ORDER BY slot FOR UPDATE SKIP LOCKED LIMIT 1;
  IF available_slot IS NULL THEN RETURN jsonb_build_object('outcome','rate_limited'); END IF;
  UPDATE public.company_tax_lookup_rate r SET used = bucket.used + 1, window_start = bucket.window_start
    WHERE r.actor_id = v_actor_id;
  UPDATE public.company_tax_lookup_slots SET lease_id = $3, auth_user_id = $1,
    lease_until = checked_at + interval '10 seconds' WHERE slot = available_slot;
  RETURN jsonb_build_object('outcome','claimed');
END; $$;
CREATE FUNCTION public.pos_release_company_tax_lookup(p_auth_user_id uuid, p_lease_id uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  UPDATE public.company_tax_lookup_slots SET lease_id = NULL, auth_user_id = NULL, lease_until = '-infinity'
    WHERE auth_user_id = $1 AND lease_id = $2;
$$;
REVOKE ALL ON FUNCTION public.pos_claim_company_tax_lookup(uuid,uuid,uuid),
  public.pos_release_company_tax_lookup(uuid,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pos_claim_company_tax_lookup(uuid,uuid,uuid),
  public.pos_release_company_tax_lookup(uuid,uuid) TO service_role;
DO $$ BEGIN
  IF has_function_privilege('authenticated','public.pos_claim_company_tax_lookup(uuid,uuid,uuid)','EXECUTE')
    OR has_function_privilege('anon','public.pos_release_company_tax_lookup(uuid,uuid)','EXECUTE')
    OR has_table_privilege('authenticated','public.company_tax_lookup_settings','SELECT')
    OR (SELECT count(*) FROM public.company_tax_lookup_slots) <> 2
    OR EXISTS (SELECT 1 FROM public.company_tax_lookup_settings WHERE enabled)
    THEN RAISE EXCEPTION 'COMPANY_TAX_LOOKUP_POLICY_DRIFT'; END IF;
END; $$;

-- First operational store pilot; Photo and SAMPLE stores remain disabled.
INSERT INTO public.company_tax_lookup_settings(store_id,enabled)
 VALUES('8bc9eef5-dcd5-46b1-b931-23f77132322c',true);
DO $release_verify$
DECLARE old record;
BEGIN
 SELECT * INTO old FROM pos_release_anchors;
 IF old.payment IS DISTINCT FROM md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))
 OR old.financials IS DISTINCT FROM (SELECT md5(COALESCE(string_agg(to_jsonb(f)::text,'' ORDER BY f.request_id),'')) FROM public.direct_order_financials f)
 OR old.issued_receipts IS DISTINCT FROM (SELECT md5(COALESCE(string_agg(snapshot::text,'' ORDER BY id),'')) FROM public.digital_receipts)
 THEN RAISE EXCEPTION 'POS_RELEASE_FINANCIAL_HISTORY_DRIFT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.company_tax_lookup_settings WHERE store_id='8bc9eef5-dcd5-46b1-b931-23f77132322c' AND enabled)
 OR (SELECT count(*) FROM public.company_tax_lookup_slots)<>2
 OR has_function_privilege('anon','public.pos_receipt_ledger_batch(date,uuid,uuid[],boolean)','EXECUTE')
 OR has_function_privilege('authenticated','public.pos_claim_company_tax_lookup(uuid,uuid,uuid)','EXECUTE')
 OR to_regprocedure('public.direct_order_public_status_v10(uuid,text,uuid)') IS NULL
 OR to_regprocedure('public.direct_order_staff_detail_v6(uuid,uuid)') IS NULL
 THEN RAISE EXCEPTION 'POS_RELEASE_CONTRACT_DRIFT'; END IF;
END; $release_verify$;
NOTIFY pgrst,'reload schema';
COMMIT;
