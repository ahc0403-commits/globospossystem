-- Recipient pays the courier; booking is separate from physical handoff.
-- production-gate: self-verifying
BEGIN;
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
COMMIT;
