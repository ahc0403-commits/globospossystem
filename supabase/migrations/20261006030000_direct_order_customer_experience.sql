-- Customer display stages and session-owned fulfillment notifications.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';

CREATE OR REPLACE FUNCTION public.direct_order_display_stage(p_state text, p_fulfillment text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT CASE
    WHEN p_state IN ('rejected','cancelled','expired') OR p_fulfillment = 'cancelled'
      THEN 'customer_exception'
    WHEN p_state = 'approved' AND p_fulfillment = 'completed' THEN 'customer_completed'
    WHEN p_state = 'approved' THEN 'customer_paid'
    ELSE 'customer_pending' END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_display_stage(text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_display_stage(text,text) TO authenticated,service_role;

-- Filter before LIMIT. Related rows are grouped for the selected page, with no
-- per-request detail/financial RPCs and no client-side truncated-page filtering.
CREATE OR REPLACE FUNCTION public.direct_order_staff_list_v3(
  p_store_id uuid, p_states text[] DEFAULT NULL, p_limit integer DEFAULT 100,
  p_fulfillment_type text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public,auth,pg_catalog AS $$
DECLARE v_day_start timestamptz;
BEGIN
  PERFORM public.direct_order_require_actor(p_store_id,
    ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 200 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_LIMIT_INVALID';
  END IF;
  IF p_fulfillment_type IS NOT NULL AND p_fulfillment_type NOT IN ('delivery','pickup') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_FULFILLMENT_INVALID';
  END IF;
  v_day_start := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh';
  RETURN (
    WITH page AS MATERIALIZED (
      SELECT r.id,r.restaurant_id,r.reference_code,r.state,r.created_at,
        CASE WHEN r.fulfillment_method='pickup' THEN 'pickup' ELSE r.fulfillment_type END AS fulfillment_type,
        t.status AS fulfillment_status,t.version AS fulfillment_version,t.completed_at,
        public.direct_order_display_stage(r.state,t.status) AS display_stage,
        EXISTS(SELECT 1 FROM public.direct_order_pickup_offers o
          JOIN public.direct_order_financials f ON f.request_id=o.request_id
          WHERE o.request_id=r.id AND o.status='accepted'
            AND o.adjustment_id IS NULL AND f.delivery_fee_total>0) AS refund_pending
      FROM public.direct_order_requests r
      LEFT JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id=r.id
      WHERE r.restaurant_id=p_store_id
        AND (p_fulfillment_type IS NULL OR
          CASE WHEN r.fulfillment_method='pickup' THEN 'pickup' ELSE r.fulfillment_type END=p_fulfillment_type)
        AND (p_states IS NULL OR r.state=ANY(p_states) OR t.status=ANY(p_states)
          OR public.direct_order_display_stage(r.state,t.status)=ANY(p_states))
        AND (r.created_at>=v_day_start AND r.created_at<v_day_start+interval '1 day'
          OR r.state IN ('awaiting_quote','quoted','awaiting_payment_review')
          OR r.state='approved' AND (t.id IS NULL OR t.status NOT IN ('completed','cancelled'))
          OR EXISTS(SELECT 1 FROM public.direct_order_pickup_offers o
            JOIN public.direct_order_financials f ON f.request_id=o.request_id
            WHERE o.request_id=r.id AND o.status='accepted'
              AND o.adjustment_id IS NULL AND f.delivery_fee_total>0))
      ORDER BY r.created_at DESC,r.id DESC LIMIT p_limit
    ), item_totals AS (
      SELECT i.request_id,sum(i.quantity) AS item_count FROM page p
      JOIN public.direct_order_request_items i ON i.request_id=p.id GROUP BY i.request_id
    ), messages AS (
      SELECT m.request_id,max(m.created_at) AS last_message_at,
        bool_or(m.message_type='payment_proof') AS has_payment_proof
      FROM page p JOIN public.direct_order_messages m ON m.request_id=p.id GROUP BY m.request_id
    ), reviews AS (
      SELECT r.request_id,bool_or(r.status='requested') AS has_open_proof_review
      FROM page p JOIN public.direct_order_proof_review_requests r ON r.request_id=p.id GROUP BY r.request_id
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'fulfillment_type',p.fulfillment_type,'id',p.id,'reference_code',p.reference_code,'state',p.state,'created_at',p.created_at,
      'customer_name',a.customer_name,'formatted_address',a.formatted_address,'district',a.district,
      'item_count',COALESCE(i.item_count,0),'final_total',q.final_total,
      'has_payment_proof',COALESCE(m.has_payment_proof,false),
      'has_open_proof_review',COALESCE(v.has_open_proof_review,false),
      'fulfillment_status',p.fulfillment_status,'fulfillment_version',p.fulfillment_version,
      'completed_at',p.completed_at,'last_message_at',m.last_message_at,
      'display_stage',p.display_stage,'refund_pending',p.refund_pending
    ) ORDER BY p.created_at DESC,p.id DESC),'[]'::jsonb)
    FROM page p
    LEFT JOIN public.direct_order_request_addresses a ON a.request_id=p.id
    LEFT JOIN LATERAL (SELECT quote.final_total FROM public.direct_order_quotes quote
      WHERE quote.request_id=p.id AND quote.status IN ('active','locked')
      ORDER BY quote.version DESC LIMIT 1) q ON true
    LEFT JOIN item_totals i ON i.request_id=p.id
    LEFT JOIN messages m ON m.request_id=p.id
    LEFT JOIN reviews v ON v.request_id=p.id
  );
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_staff_list_v3(uuid,text[],integer,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_list_v3(uuid,text[],integer,text) TO authenticated,service_role;

CREATE TABLE public.direct_order_push_devices (
  session_id uuid NOT NULL REFERENCES public.direct_order_sessions(id) ON DELETE CASCADE,
  device_id uuid NOT NULL,
  push_token text NOT NULL CHECK(char_length(push_token) BETWEEN 16 AND 2048),
  locale text NOT NULL CHECK(locale IN ('ko','vi','en')),
  enabled boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(session_id,device_id)
);
CREATE UNIQUE INDEX direct_order_push_session_token ON public.direct_order_push_devices(session_id,md5(push_token));
CREATE TABLE public.direct_order_customer_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  request_id uuid NOT NULL REFERENCES public.direct_order_requests(id) ON DELETE CASCADE,
  session_id uuid NOT NULL REFERENCES public.direct_order_sessions(id) ON DELETE CASCADE,
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE CASCADE,
  event_kind text NOT NULL CHECK(event_kind IN ('pickup_ready','driver_handoff')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(request_id,event_kind)
);
CREATE TABLE public.direct_order_push_deliveries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id uuid NOT NULL REFERENCES public.direct_order_customer_events(id) ON DELETE CASCADE,
  session_id uuid NOT NULL,
  device_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','sending','sent','failed','skipped')),
  attempts integer NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 5),
  available_at timestamptz NOT NULL DEFAULT now(),
  lease_id uuid,
  lease_until timestamptz,
  last_error text,
  UNIQUE(event_id,session_id,device_id),
  FOREIGN KEY(session_id,device_id) REFERENCES public.direct_order_push_devices(session_id,device_id) ON DELETE CASCADE
);
CREATE INDEX direct_order_push_pending ON public.direct_order_push_deliveries(available_at,id)
  WHERE status IN ('pending','sending');
CREATE INDEX direct_order_customer_events_session ON public.direct_order_customer_events(session_id);
ALTER TABLE public.direct_order_push_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_order_customer_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.direct_order_push_deliveries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.direct_order_push_devices,public.direct_order_customer_events,public.direct_order_push_deliveries FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.direct_order_push_devices,public.direct_order_customer_events,public.direct_order_push_deliveries TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_public_push_subscription(
  p_session_id uuid,p_secret_hash text,p_device_id uuid,p_token text,p_locale text,p_enabled boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
  PERFORM public.direct_order_validate_session(p_session_id,p_secret_hash);
  IF p_device_id IS NULL OR p_enabled IS NULL OR p_locale IS NULL
    OR p_locale NOT IN ('ko','vi','en') OR (p_enabled AND
      (p_token IS NULL OR char_length(p_token) NOT BETWEEN 16 AND 2048 OR p_token !~ '^[A-Za-z0-9_:-]+$')) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PUSH_INPUT_INVALID';
  END IF;
  PERFORM 1 FROM public.direct_order_sessions WHERE id=p_session_id FOR UPDATE;
  IF NOT p_enabled THEN
    UPDATE public.direct_order_push_devices SET enabled=false,updated_at=now()
      WHERE session_id=p_session_id AND device_id=p_device_id;
  ELSE
    IF NOT EXISTS(SELECT 1 FROM public.direct_order_push_devices WHERE session_id=p_session_id AND device_id=p_device_id)
      AND (SELECT count(*) FROM public.direct_order_push_devices WHERE session_id=p_session_id)>=5 THEN
      RAISE EXCEPTION 'DIRECT_ORDER_PUSH_DEVICE_LIMIT';
    END IF;
    -- A browser token belongs to one device identity per customer session.
    DELETE FROM public.direct_order_push_devices WHERE session_id=p_session_id
      AND md5(push_token)=md5(p_token) AND device_id<>p_device_id;
    INSERT INTO public.direct_order_push_devices(session_id,device_id,push_token,locale,enabled)
      VALUES(p_session_id,p_device_id,p_token,p_locale,true)
      ON CONFLICT(session_id,device_id) DO UPDATE SET push_token=EXCLUDED.push_token,
        locale=EXCLUDED.locale,enabled=true,updated_at=now();
  END IF;
  RETURN jsonb_build_object('enabled',p_enabled);
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_public_push_subscription(uuid,text,uuid,text,text,boolean) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_push_subscription(uuid,text,uuid,text,text,boolean) TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_enqueue_customer_event(p_request_id uuid,p_kind text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE v_request public.direct_order_requests%ROWTYPE; v_event_id uuid;
BEGIN
  SELECT * INTO v_request FROM public.direct_order_requests WHERE id=p_request_id FOR UPDATE;
  IF NOT FOUND OR v_request.state<>'approved' THEN RETURN; END IF;
  IF p_kind='pickup_ready' THEN
    IF (v_request.fulfillment_method<>'pickup' AND v_request.fulfillment_type<>'pickup') OR NOT EXISTS(SELECT 1 FROM public.direct_delivery_fulfillment_tickets
      WHERE request_id=p_request_id AND status='ready') THEN RETURN; END IF;
  ELSIF p_kind='driver_handoff' THEN
    IF (v_request.fulfillment_method<>'delivery' OR v_request.fulfillment_type='pickup') OR NOT EXISTS(SELECT 1 FROM public.direct_order_dispatches
      WHERE request_id=p_request_id) THEN RETURN; END IF;
  ELSE RAISE EXCEPTION 'DIRECT_ORDER_PUSH_INPUT_INVALID'; END IF;
  PERFORM 1 FROM public.direct_order_sessions WHERE id=v_request.session_id FOR UPDATE;
  INSERT INTO public.direct_order_customer_events(request_id,session_id,restaurant_id,event_kind)
    VALUES(v_request.id,v_request.session_id,v_request.restaurant_id,p_kind)
    ON CONFLICT(request_id,event_kind) DO NOTHING RETURNING id INTO v_event_id;
  IF v_event_id IS NULL THEN RETURN; END IF;
  IF p_kind='pickup_ready' THEN
    INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body)
      VALUES(v_request.id,v_request.restaurant_id,'system','system','DIRECT_ORDER_PICKUP_READY');
  END IF;
  INSERT INTO public.direct_order_push_deliveries(event_id,session_id,device_id)
    SELECT v_event_id,d.session_id,d.device_id FROM public.direct_order_push_devices d
    JOIN public.direct_order_sessions s ON s.id=d.session_id
    WHERE d.session_id=v_request.session_id AND d.enabled AND s.expires_at>now() AND s.revoked_at IS NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_enqueue_customer_event(uuid,text) FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.direct_order_customer_event_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
  IF TG_TABLE_NAME='direct_order_dispatches' THEN
    PERFORM public.direct_order_enqueue_customer_event(NEW.request_id,'driver_handoff');
  ELSIF TG_TABLE_NAME='direct_order_requests' THEN
    IF NEW.fulfillment_method='pickup' AND OLD.fulfillment_method IS DISTINCT FROM NEW.fulfillment_method THEN
      PERFORM public.direct_order_enqueue_customer_event(NEW.id,'pickup_ready');
    END IF;
  ELSIF NEW.status='ready' AND OLD.status IS DISTINCT FROM NEW.status THEN
    PERFORM public.direct_order_enqueue_customer_event(NEW.request_id,'pickup_ready');
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_customer_event_trigger() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER direct_order_pickup_ready_notice AFTER UPDATE OF status ON public.direct_delivery_fulfillment_tickets
  FOR EACH ROW EXECUTE FUNCTION public.direct_order_customer_event_trigger();
CREATE TRIGGER direct_order_pickup_conversion_notice AFTER UPDATE OF fulfillment_method ON public.direct_order_requests
  FOR EACH ROW EXECUTE FUNCTION public.direct_order_customer_event_trigger();
CREATE TRIGGER direct_order_driver_handoff_notice AFTER INSERT ON public.direct_order_dispatches
  FOR EACH ROW EXECUTE FUNCTION public.direct_order_customer_event_trigger();

-- Tray completion means packed/ready; driver handoff requires a dispatch record.
-- Keep the existing paperless event routing and timestamps except handoff time.
DO $kds_ready$
DECLARE v_def text; v_original text;
BEGIN
  IF to_regprocedure('public.sync_direct_delivery_ticket_from_kds()') IS NOT NULL THEN
    v_def:=pg_get_functiondef('public.sync_direct_delivery_ticket_from_kds()'::regprocedure);
    v_original:=v_def;
    IF strpos(v_def,'  SELECT ticket.* INTO v_ticket')=0
      OR strpos(v_def,'SET status = ''dispatched'',')=0
      OR strpos(v_def,'v_ticket.status IN (''pending'', ''preparing'', ''ready'')')=0
      OR strpos(v_def,E'        dispatched_at = COALESCE(dispatched_at, now()),\n')=0 THEN
      RAISE EXCEPTION 'DIRECT_ORDER_KDS_READY_ANCHOR_DRIFT';
    END IF;
    IF (length(v_def)-length(replace(v_def,E'BEGIN\n','')))/length(E'BEGIN\n')<>1 THEN
      RAISE EXCEPTION 'DIRECT_ORDER_KDS_READY_ANCHOR_DRIFT';
    END IF;
    -- Both native pickup and delivery acquire request before ticket, matching
    -- dispatch/consent/notification writers and preventing lock inversion.
    v_def:=replace(v_def,E'BEGIN\n',E'BEGIN\n  IF NEW.stage IN (''kitchen_done'',''tray_dispatched'') THEN\n    PERFORM 1 FROM public.direct_order_requests WHERE id=(SELECT request_id FROM public.direct_order_financials WHERE order_id=NEW.order_id) FOR UPDATE;\n  END IF;\n');
    v_def:=replace(v_def, 'SET status = ''dispatched'',', 'SET status = ''ready'',');
    v_def:=replace(v_def, 'v_ticket.status IN (''pending'', ''preparing'', ''ready'')',
      'v_ticket.status IN (''pending'', ''preparing'')');
    v_def:=replace(v_def, E'        dispatched_at = COALESCE(dispatched_at, now()),\n', '');
    IF v_def=v_original OR strpos(v_def, 'SET status = ''dispatched''')>0 THEN
      RAISE EXCEPTION 'DIRECT_ORDER_KDS_READY_ANCHOR_DRIFT';
    END IF;
    EXECUTE v_def;
  END IF;
END;
$kds_ready$;

CREATE OR REPLACE FUNCTION public.claim_direct_order_push_deliveries(p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE v_rows jsonb;
BEGIN
  IF p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'DIRECT_ORDER_LIMIT_INVALID'; END IF;
  -- Expired, disabled and terminal orders must not receive stale ready notices.
  UPDATE public.direct_order_push_deliveries q SET status='skipped',lease_id=NULL,lease_until=NULL
    FROM public.direct_order_customer_events e,public.direct_order_push_devices d,
      public.direct_order_sessions s,public.direct_order_requests r
    WHERE q.event_id=e.id AND d.session_id=q.session_id AND d.device_id=q.device_id
      AND s.id=q.session_id AND r.id=e.request_id AND q.status IN ('pending','sending')
      AND (q.status='pending' OR q.lease_until<=now())
      AND (NOT d.enabled OR s.expires_at<=now() OR s.revoked_at IS NOT NULL OR r.state<>'approved'
        OR e.created_at<now()-interval '1 day'
        OR EXISTS(SELECT 1 FROM public.direct_delivery_fulfillment_tickets t
          WHERE t.request_id=r.id AND t.status IN ('completed','cancelled')));
  UPDATE public.direct_order_push_deliveries SET status='failed',lease_id=NULL,lease_until=NULL
    WHERE status='sending' AND lease_until<=now() AND attempts>=5;
    WITH picked AS (
      SELECT q.id FROM public.direct_order_push_deliveries q
      WHERE ((q.status='pending' AND q.available_at<=now()) OR
        (q.status='sending' AND q.lease_until<=now())) AND q.attempts<5
      ORDER BY q.available_at,q.id LIMIT p_limit FOR UPDATE SKIP LOCKED
    ), claimed AS (
      UPDATE public.direct_order_push_deliveries q SET status='sending',attempts=attempts+1,
        lease_id=gen_random_uuid(),lease_until=now()+interval '2 minutes'
      FROM picked p WHERE q.id=p.id RETURNING q.*
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id',c.id,'lease_id',c.lease_id,'attempts',c.attempts,'event_id',e.id,
      'event_kind',e.event_kind,'request_id',r.id,'reference_code',r.reference_code,
      'slug',sf.public_slug,'store_name',shop.name,'locale',d.locale,
      'push_token',d.push_token,'token_hash',md5(d.push_token)
    )),'[]'::jsonb) INTO v_rows
    FROM claimed c JOIN public.direct_order_customer_events e ON e.id=c.event_id
    JOIN public.direct_order_requests r ON r.id=e.request_id
    JOIN public.direct_order_storefronts sf ON sf.restaurant_id=e.restaurant_id
    JOIN public.restaurants shop ON shop.id=e.restaurant_id
    JOIN public.direct_order_push_devices d ON d.session_id=c.session_id AND d.device_id=c.device_id;
  RETURN v_rows;
END;
$$;
REVOKE ALL ON FUNCTION public.claim_direct_order_push_deliveries(integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.claim_direct_order_push_deliveries(integer) TO service_role;

CREATE OR REPLACE FUNCTION public.complete_direct_order_push_delivery(
  p_delivery_id uuid,p_lease_id uuid,p_outcome text,p_token_hash text
) RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE v_delivery public.direct_order_push_deliveries%ROWTYPE;
BEGIN
  IF p_outcome IS NULL OR p_outcome NOT IN ('sent','retry','invalid_token','failed') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PUSH_INPUT_INVALID';
  END IF;
  SELECT * INTO v_delivery FROM public.direct_order_push_deliveries WHERE id=p_delivery_id FOR UPDATE;
  IF NOT FOUND OR v_delivery.status<>'sending' OR v_delivery.lease_id IS DISTINCT FROM p_lease_id
    OR v_delivery.lease_until<=now() THEN RETURN false; END IF;
  IF p_outcome='invalid_token' THEN
    UPDATE public.direct_order_push_devices SET enabled=false,updated_at=now()
      WHERE session_id=v_delivery.session_id AND device_id=v_delivery.device_id
        AND md5(push_token)=p_token_hash;
  END IF;
  UPDATE public.direct_order_push_deliveries SET
    status=CASE WHEN p_outcome='sent' THEN 'sent'
      WHEN p_outcome='retry' AND attempts<5 THEN 'pending' ELSE 'failed' END,
    available_at=now()+make_interval(secs=>LEAST(3600,30*power(2,attempts-1))::integer),
    lease_id=NULL,lease_until=NULL,
    last_error=CASE WHEN p_outcome='sent' THEN NULL ELSE p_outcome END
    WHERE id=p_delivery_id;
  RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.complete_direct_order_push_delivery(uuid,uuid,text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.complete_direct_order_push_delivery(uuid,uuid,text,text) TO service_role;

DO $schedule$
BEGIN
  IF EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_cron')
    AND EXISTS(SELECT 1 FROM pg_extension WHERE extname='pg_net') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname='direct-order-customer-push-every-minute';
    PERFORM cron.schedule('direct-order-customer-push-every-minute','* * * * *',$job$
      SELECT net.http_post(
        url:='https://ynriuoomotxuwhuxxmhj.supabase.co/functions/v1/direct-order-notification-dispatcher',
        headers:=jsonb_build_object('Authorization','Bearer '||(
          SELECT decrypted_secret FROM vault.decrypted_secrets
          WHERE name IN ('cron_secret','app.settings.cron_secret')
          ORDER BY (name='cron_secret') DESC LIMIT 1),'Content-Type','application/json'),
        body:='{}'::jsonb
      )
    $job$);
  END IF;
EXCEPTION WHEN invalid_schema_name OR undefined_function OR insufficient_privilege THEN
  RAISE NOTICE 'Customer push schedule unavailable; configure scheduler before release.';
END;
$schedule$;

DO $verify$
BEGIN
  IF to_regprocedure('public.direct_order_staff_list_v3(uuid,text[],integer,text)') IS NULL
    OR to_regprocedure('public.direct_order_public_push_subscription(uuid,text,uuid,text,text,boolean)') IS NULL
    OR (SELECT count(*) FROM pg_trigger WHERE tgname IN
      ('direct_order_pickup_ready_notice','direct_order_pickup_conversion_notice','direct_order_driver_handoff_notice') AND NOT tgisinternal)<>3
    OR has_function_privilege('anon','public.claim_direct_order_push_deliveries(integer)','EXECUTE')
    OR has_function_privilege('authenticated','public.direct_order_public_push_subscription(uuid,text,uuid,text,text,boolean)','EXECUTE')
    OR has_table_privilege('authenticated','public.direct_order_push_devices','SELECT') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CUSTOMER_EXPERIENCE_CONTRACT_FAILED';
  END IF;
END;
$verify$;
COMMIT;
