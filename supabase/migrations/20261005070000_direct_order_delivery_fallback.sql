-- Direct Order diner counts, provider-neutral dispatch and consented pickup.
-- Existing payment, inventory, MISA and legacy public projections are preserved.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';

ALTER TABLE public.direct_order_requests
  ADD COLUMN diner_count integer CHECK (diner_count BETWEEN 1 AND 100),
  ADD COLUMN fulfillment_method text NOT NULL DEFAULT 'delivery'
    CHECK (fulfillment_method IN ('delivery', 'pickup')),
  ADD COLUMN fulfillment_version integer NOT NULL DEFAULT 1 CHECK (fulfillment_version > 0);

UPDATE public.direct_order_requests SET fulfillment_method='pickup' WHERE fulfillment_type='pickup';

-- Legacy native-pickup clients also keep the effective method synchronized.
CREATE FUNCTION public.direct_order_initialize_fulfillment_method()
RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
BEGIN
  NEW.fulfillment_method := NEW.fulfillment_type;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_initialize_fulfillment_method() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER direct_order_initialize_fulfillment_method BEFORE INSERT ON public.direct_order_requests
FOR EACH ROW EXECUTE FUNCTION public.direct_order_initialize_fulfillment_method();

CREATE OR REPLACE FUNCTION public.direct_order_tracking_url_valid(p_url text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = pg_catalog AS $$
  SELECT p_url IS NULL OR (
    char_length(p_url) <= 2000 AND p_url ~*
      '^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?([/?#][^[:space:][:cntrl:]]*)?$'
  );
$$;
REVOKE ALL ON FUNCTION public.direct_order_tracking_url_valid(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.direct_order_tracking_url_valid(text) TO service_role;

ALTER TABLE public.direct_order_dispatches
  ALTER COLUMN grab_tracking_url DROP NOT NULL,
  ADD COLUMN delivery_provider text NOT NULL DEFAULT 'grab'
    CHECK (delivery_provider IN ('grab', 'be', 'other')),
  ADD COLUMN provider_name text CHECK (char_length(provider_name) BETWEEN 1 AND 100),
  ADD COLUMN driver_contact text CHECK (char_length(driver_contact) BETWEEN 1 AND 200),
  DROP CONSTRAINT direct_order_dispatches_url_valid,
  ADD CONSTRAINT direct_order_dispatches_url_valid CHECK (
    public.direct_order_tracking_url_valid(grab_tracking_url)
    AND (grab_tracking_url IS NOT NULL OR NULLIF(btrim(driver_contact), '') IS NOT NULL)
    AND (delivery_provider <> 'other' OR NULLIF(btrim(provider_name), '') IS NOT NULL)
  );

CREATE TABLE public.direct_order_pickup_offers (
  request_id uuid PRIMARY KEY REFERENCES public.direct_order_requests(id) ON DELETE RESTRICT,
  id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
  restaurant_id uuid NOT NULL REFERENCES public.restaurants(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'proposed' CHECK (status IN ('proposed', 'accepted', 'declined')),
  expected_method_version integer NOT NULL,
  quote_id uuid REFERENCES public.direct_order_quotes(id) ON DELETE RESTRICT,
  reason text NOT NULL CHECK (char_length(btrim(reason)) BETWEEN 1 AND 500),
  proposed_by uuid NOT NULL REFERENCES auth.users(id),
  proposed_at timestamptz NOT NULL DEFAULT now(),
  decided_at timestamptz,
  adjustment_id uuid UNIQUE REFERENCES public.payment_adjustments(id) ON DELETE RESTRICT,
  refund_reference text CHECK (char_length(btrim(refund_reference)) BETWEEN 1 AND 200),
  refunded_at timestamptz,
  CHECK ((adjustment_id IS NULL AND refunded_at IS NULL AND refund_reference IS NULL)
    OR (adjustment_id IS NOT NULL AND refunded_at IS NOT NULL AND refund_reference IS NOT NULL))
);
CREATE INDEX direct_order_pickup_offers_store ON public.direct_order_pickup_offers(restaurant_id, status);
ALTER TABLE public.direct_order_pickup_offers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.direct_order_pickup_offers FROM PUBLIC, anon, authenticated;
GRANT ALL ON TABLE public.direct_order_pickup_offers TO service_role;

-- Service-only helper. Authorized public/staff RPCs below validate ownership first.
CREATE OR REPLACE FUNCTION public.direct_order_fulfillment_context(p_request_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_catalog AS $$
  SELECT jsonb_build_object(
    'diner_count', r.diner_count, 'method', r.fulfillment_method, 'version', r.fulfillment_version,
    'store_name', s.name, 'store_address', s.address,
    'provider', d.delivery_provider, 'provider_name', d.provider_name,
    'tracking_url', d.grab_tracking_url, 'driver_contact', d.driver_contact,
    'pickup_offer', CASE WHEN o.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', o.id, 'status', o.status, 'reason', o.reason,
      'refund_due', CASE WHEN o.status <> 'declined' THEN COALESCE(f.delivery_fee_total, q.delivery_fee_total, 0) ELSE 0 END,
      'refund_recorded', o.adjustment_id IS NOT NULL, 'refunded_at', o.refunded_at
    ) END,
    'paid_total', f.final_total,
    'refunded_total', COALESCE((SELECT sum(a.amount) FROM public.payment_adjustments a
      WHERE a.payment_id = f.payment_id), 0)
  )
  FROM public.direct_order_requests r JOIN public.restaurants s ON s.id = r.restaurant_id
  LEFT JOIN public.direct_order_dispatches d ON d.request_id = r.id
  LEFT JOIN public.direct_order_pickup_offers o ON o.request_id = r.id
  LEFT JOIN public.direct_order_financials f ON f.request_id = r.id
  LEFT JOIN LATERAL (SELECT delivery_fee_total FROM public.direct_order_quotes
    WHERE request_id = r.id AND status IN ('active', 'locked') ORDER BY version DESC LIMIT 1) q ON true
  WHERE r.id = p_request_id;
$$;
REVOKE ALL ON FUNCTION public.direct_order_fulfillment_context(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_fulfillment_context(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.direct_order_public_submit_v3(
  p_session_id uuid, p_secret_hash text, p_client_request_id uuid, p_payload jsonb
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_session public.direct_order_sessions%ROWTYPE; v_result jsonb; v_count integer;
BEGIN
  v_session := public.direct_order_validate_session(p_session_id, p_secret_hash);
  -- Previously committed requests remain replayable, including pre-count clients.
  IF EXISTS (SELECT 1 FROM public.direct_order_requests WHERE client_request_id = p_client_request_id) THEN
    RETURN public.direct_order_public_submit_v2(p_session_id, p_secret_hash, p_client_request_id, p_payload);
  END IF;
  IF jsonb_typeof(p_payload->'diner_count') IS DISTINCT FROM 'number'
    OR (p_payload->>'diner_count') !~ '^[0-9]{1,3}$' THEN
    RAISE EXCEPTION 'DIRECT_ORDER_DINER_COUNT_INVALID';
  END IF;
  v_count := (p_payload->>'diner_count')::integer;
  IF v_count NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'DIRECT_ORDER_DINER_COUNT_INVALID'; END IF;
  v_result := public.direct_order_public_submit_v2(p_session_id, p_secret_hash, p_client_request_id, p_payload);
  IF NOT (v_result->>'idempotent')::boolean THEN
    UPDATE public.direct_order_requests SET diner_count = v_count, fulfillment_method = fulfillment_type WHERE id = (v_result->>'request_id')::uuid;
  END IF;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.direct_order_public_status_v3(
  p_session_id uuid, p_secret_hash text, p_request_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_base jsonb;
BEGIN
  v_base := public.direct_order_public_status_v2(p_session_id, p_secret_hash, p_request_id);
  v_base := v_base || jsonb_build_object('fulfillment_type', (SELECT fulfillment_type FROM public.direct_order_requests WHERE id=p_request_id));
  IF v_base->'dispatch'->>'grab_tracking_url' IS NULL THEN v_base := jsonb_set(v_base,'{dispatch}','null'::jsonb); END IF;
  RETURN v_base || jsonb_build_object('delivery', public.direct_order_fulfillment_context(p_request_id));
END;
$$;

CREATE OR REPLACE FUNCTION public.direct_order_public_resume_storefront(p_session_id uuid, p_secret_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_session public.direct_order_sessions%ROWTYPE; v_result jsonb;
BEGIN
  v_session := public.direct_order_validate_session(p_session_id, p_secret_hash);
  IF NOT EXISTS (SELECT 1 FROM public.direct_order_requests WHERE session_id = v_session.id) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_NOT_FOUND';
  END IF;
  SELECT public.direct_order_public_storefront(public_slug) INTO v_result
  FROM public.direct_order_storefronts WHERE restaurant_id = v_session.restaurant_id;
  IF v_result IS NOT NULL THEN
    RETURN v_result || jsonb_build_object('store_address', (SELECT address FROM public.restaurants WHERE id=v_session.restaurant_id));
  END IF;
  SELECT jsonb_build_object('store_id', s.id, 'store_name', s.name, 'store_address', s.address, 'slug', sf.public_slug,
    'paused', true, 'ordering_starts_at', sf.ordering_starts_at, 'ordering_cutoff_at', sf.ordering_cutoff_at,
    'minimum_order_amount', sf.minimum_order_amount, 'default_latitude', sf.default_latitude,
    'default_longitude', sf.default_longitude, 'categories', '[]'::jsonb, 'items', '[]'::jsonb,
    'bank', jsonb_build_object('bin', sf.bank_bin, 'account_number', sf.bank_account_number,
      'account_holder', sf.bank_account_holder, 'label', sf.bank_label)) INTO v_result
  FROM public.restaurants s JOIN public.direct_order_storefronts sf ON sf.restaurant_id = s.id
  WHERE s.id = v_session.restaurant_id;
  IF v_result IS NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_NOT_FOUND'; END IF;
  RETURN v_result;
END;
$$;

CREATE OR REPLACE FUNCTION public.direct_order_staff_detail_v3(p_store_id uuid, p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, auth, pg_catalog AS $$
DECLARE v_base jsonb;
BEGIN
  v_base := public.direct_order_staff_detail_v2(p_store_id, p_request_id);
  RETURN v_base || jsonb_build_object('delivery', public.direct_order_fulfillment_context(p_request_id));
END;
$$;

CREATE OR REPLACE FUNCTION public.direct_order_staff_set_diner_count(
  p_store_id uuid, p_request_id uuid, p_expected_version integer, p_diner_count integer
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, pg_catalog AS $$
DECLARE v_request public.direct_order_requests%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(p_store_id, ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
  SELECT * INTO v_request FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
  IF p_diner_count IS NULL OR p_diner_count NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'DIRECT_ORDER_DINER_COUNT_INVALID'; END IF;
  IF v_request.fulfillment_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'DIRECT_ORDER_FULFILLMENT_CHANGED'; END IF;
  IF v_request.state IN ('rejected','cancelled','expired') OR EXISTS (
    SELECT 1 FROM public.direct_delivery_fulfillment_tickets WHERE request_id=p_request_id AND status IN ('dispatched','completed','cancelled')
  ) THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_NOT_ALLOWED'; END IF;
  UPDATE public.direct_order_requests SET diner_count=p_diner_count, fulfillment_version=fulfillment_version+1, updated_at=now() WHERE id=p_request_id;
  UPDATE public.orders SET guest_count=p_diner_count WHERE id=(SELECT order_id FROM public.direct_order_financials WHERE request_id=p_request_id);
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES
    (auth.uid(),'direct_order_diner_count_changed','direct_order_requests',p_request_id,
      jsonb_build_object('previous',v_request.diner_count,'diner_count',p_diner_count));
  RETURN public.direct_order_fulfillment_context(p_request_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.direct_order_staff_offer_pickup(
  p_store_id uuid, p_request_id uuid, p_expected_version integer, p_reason text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, pg_catalog AS $$
DECLARE v_request public.direct_order_requests%ROWTYPE; v_offer public.direct_order_pickup_offers%ROWTYPE; v_quote uuid;
BEGIN
  PERFORM public.direct_order_require_actor(p_store_id, ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
  SELECT * INTO v_request FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
  IF char_length(btrim(COALESCE(p_reason,''))) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_INPUT_INVALID'; END IF;
  SELECT id INTO v_quote FROM public.direct_order_quotes WHERE request_id=p_request_id AND status IN ('active','locked') ORDER BY version DESC LIMIT 1;
  SELECT * INTO v_offer FROM public.direct_order_pickup_offers WHERE request_id=p_request_id;
  IF FOUND AND v_offer.status='proposed' AND v_offer.expected_method_version=p_expected_version
    AND v_offer.quote_id IS NOT DISTINCT FROM v_quote AND v_offer.reason=btrim(p_reason)
    THEN RETURN public.direct_order_fulfillment_context(p_request_id); END IF;
  IF v_request.fulfillment_version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'DIRECT_ORDER_FULFILLMENT_CHANGED'; END IF;
  IF v_request.fulfillment_method<>'delivery' OR v_request.state IN ('rejected','cancelled','expired')
    OR EXISTS(SELECT 1 FROM public.direct_order_dispatches WHERE request_id=p_request_id)
    OR EXISTS(SELECT 1 FROM public.direct_delivery_fulfillment_tickets WHERE request_id=p_request_id AND status IN ('dispatched','completed','cancelled'))
  THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_NOT_ALLOWED'; END IF;
  INSERT INTO public.direct_order_pickup_offers(request_id,restaurant_id,expected_method_version,quote_id,reason,proposed_by)
  VALUES(p_request_id,p_store_id,p_expected_version,v_quote,btrim(p_reason),auth.uid())
  ON CONFLICT(request_id) DO UPDATE SET id=gen_random_uuid(),status='proposed',expected_method_version=EXCLUDED.expected_method_version,
    quote_id=EXCLUDED.quote_id,reason=EXCLUDED.reason,proposed_by=EXCLUDED.proposed_by,proposed_at=now(),decided_at=NULL;
  INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body)
    VALUES(p_request_id,p_store_id,'system','system','DIRECT_ORDER_PICKUP_OFFERED');
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES
    (auth.uid(),'direct_order_pickup_offered','direct_order_requests',p_request_id,jsonb_build_object('reason',btrim(p_reason)));
  RETURN public.direct_order_fulfillment_context(p_request_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.direct_order_public_decide_pickup(
  p_session_id uuid, p_secret_hash text, p_request_id uuid, p_offer_id uuid, p_accept boolean, p_already_paid boolean DEFAULT false
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_catalog AS $$
DECLARE v_session public.direct_order_sessions%ROWTYPE; v_request public.direct_order_requests%ROWTYPE;
  v_offer public.direct_order_pickup_offers%ROWTYPE; v_quote uuid;
BEGIN
  v_session := public.direct_order_validate_session(p_session_id,p_secret_hash);
  SELECT * INTO v_request FROM public.direct_order_requests WHERE id=p_request_id AND session_id=v_session.id AND restaurant_id=v_session.restaurant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
  SELECT * INTO v_offer FROM public.direct_order_pickup_offers WHERE request_id=p_request_id AND id=p_offer_id FOR UPDATE;
  IF NOT FOUND OR p_accept IS NULL OR p_already_paid IS NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_INPUT_INVALID'; END IF;
  IF v_offer.status = (CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END) THEN RETURN public.direct_order_fulfillment_context(p_request_id); END IF;
  IF v_offer.status<>'proposed' OR (p_accept AND v_request.fulfillment_version<>v_offer.expected_method_version) THEN RAISE EXCEPTION 'DIRECT_ORDER_FULFILLMENT_CHANGED'; END IF;
  IF v_request.state IN ('rejected','cancelled','expired') OR v_request.fulfillment_method<>'delivery'
    OR EXISTS(SELECT 1 FROM public.direct_order_dispatches WHERE request_id=p_request_id)
    OR EXISTS(SELECT 1 FROM public.direct_delivery_fulfillment_tickets WHERE request_id=p_request_id AND status IN ('dispatched','completed','cancelled'))
  THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_NOT_ALLOWED'; END IF;
  SELECT id INTO v_quote FROM public.direct_order_quotes WHERE request_id=p_request_id AND status IN ('active','locked') ORDER BY version DESC LIMIT 1;
  IF p_accept AND v_quote IS DISTINCT FROM v_offer.quote_id THEN RAISE EXCEPTION 'DIRECT_ORDER_FULFILLMENT_CHANGED'; END IF;
  UPDATE public.direct_order_pickup_offers SET status=CASE WHEN p_accept THEN 'accepted' ELSE 'declined' END, decided_at=now() WHERE request_id=p_request_id;
  IF p_accept THEN
    UPDATE public.direct_order_requests SET fulfillment_method='pickup',fulfillment_version=fulfillment_version+1,updated_at=now() WHERE id=p_request_id;
    -- A customer who has already transferred keeps the original quote/proof.
    IF v_request.state IN ('awaiting_quote','quoted') AND NOT p_already_paid THEN
      UPDATE public.direct_order_quotes SET status='superseded' WHERE request_id=p_request_id AND status='active';
      UPDATE public.direct_order_requests SET state='awaiting_quote' WHERE id=p_request_id;
    END IF;
  END IF;
  INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body)
    VALUES(p_request_id,v_request.restaurant_id,'system','system',CASE WHEN p_accept THEN 'DIRECT_ORDER_PICKUP_ACCEPTED' ELSE 'DIRECT_ORDER_PICKUP_DECLINED' END);
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES
    (NULL,'direct_order_pickup_decided','direct_order_requests',p_request_id,jsonb_build_object('offer_id',p_offer_id,'accepted',p_accept,'already_paid',p_already_paid,'session_id',v_session.id));
  RETURN public.direct_order_fulfillment_context(p_request_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.direct_order_staff_record_pickup_refund(
  p_store_id uuid,p_request_id uuid,p_offer_id uuid,p_reference text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, pg_catalog AS $$
DECLARE v_offer public.direct_order_pickup_offers%ROWTYPE; v_fin public.direct_order_financials%ROWTYPE;
  v_payment public.payments%ROWTYPE; v_adjustment public.payment_adjustments%ROWTYPE;
BEGIN
  PERFORM public.direct_order_require_actor(p_store_id,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
  PERFORM 1 FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id AND fulfillment_method='pickup' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_NOT_ALLOWED'; END IF;
  SELECT * INTO v_offer FROM public.direct_order_pickup_offers WHERE request_id=p_request_id AND id=p_offer_id AND status='accepted' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_NOT_ALLOWED'; END IF;
  IF v_offer.adjustment_id IS NOT NULL THEN RETURN public.direct_order_fulfillment_context(p_request_id); END IF;
  IF char_length(btrim(COALESCE(p_reference,''))) NOT BETWEEN 1 AND 200 THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_INPUT_INVALID'; END IF;
  SELECT * INTO v_fin FROM public.direct_order_financials WHERE request_id=p_request_id AND restaurant_id=p_store_id;
  IF NOT FOUND OR v_fin.delivery_fee_total<=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_NOT_DUE'; END IF;
  SELECT * INTO v_payment FROM public.payments WHERE id=v_fin.payment_id FOR UPDATE;
  IF upper(v_payment.method)<>'BANKTRANSFER' OR EXISTS(SELECT 1 FROM public.payment_adjustments WHERE payment_id=v_fin.payment_id)
    THEN RAISE EXCEPTION 'DIRECT_ORDER_REFUND_RECONCILIATION_REQUIRED'; END IF;
  v_adjustment := public.record_payment_adjustment(v_fin.payment_id,'refund',v_fin.delivery_fee_total,
    'Pickup delivery fee refund: '||btrim(p_reference));
  UPDATE public.direct_order_pickup_offers SET adjustment_id=v_adjustment.id,refund_reference=btrim(p_reference),refunded_at=now() WHERE request_id=p_request_id;
  INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body)
    VALUES(p_request_id,p_store_id,'system','system','DIRECT_ORDER_PICKUP_REFUNDED');
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES
    (auth.uid(),'direct_order_pickup_refund_recorded','direct_order_requests',p_request_id,
      jsonb_build_object('adjustment_id',v_adjustment.id,'delivery_fee_item_id',v_fin.delivery_fee_item_id,'amount',v_fin.delivery_fee_total,'reference',btrim(p_reference)));
  RETURN public.direct_order_fulfillment_context(p_request_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.direct_order_set_dispatch_v3(
  p_store_id uuid,p_request_id uuid,p_expected_version integer,p_provider text,
  p_tracking_url text DEFAULT NULL,p_actual_fee numeric DEFAULT NULL,p_provider_name text DEFAULT NULL,p_driver_contact text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, pg_catalog AS $$
DECLARE v_request public.direct_order_requests%ROWTYPE; v_ticket public.direct_delivery_fulfillment_tickets%ROWTYPE;
  v_fin public.direct_order_financials%ROWTYPE; v_dispatch public.direct_order_dispatches%ROWTYPE;
  v_url text:=NULLIF(btrim(p_tracking_url),''); v_contact text:=NULLIF(btrim(p_driver_contact),''); v_name text:=NULLIF(btrim(p_provider_name),'');
BEGIN
  PERFORM public.direct_order_require_actor(p_store_id,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
  SELECT * INTO v_request FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id FOR UPDATE;
  IF NOT FOUND OR v_request.state<>'approved' THEN RAISE EXCEPTION 'DIRECT_ORDER_NOT_APPROVED'; END IF;
  IF v_request.fulfillment_method<>'delivery' THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_NOT_ALLOWED'; END IF;
  IF p_provider IS NULL OR p_provider NOT IN ('grab','be','other') OR (p_provider='other' AND v_name IS NULL)
    OR NOT public.direct_order_tracking_url_valid(v_url) OR (v_url IS NULL AND v_contact IS NULL)
    OR char_length(v_contact)>200 OR char_length(v_name)>100 THEN RAISE EXCEPTION 'DIRECT_ORDER_DISPATCH_INPUT_INVALID'; END IF;
  SELECT * INTO v_fin FROM public.direct_order_financials WHERE request_id=p_request_id AND restaurant_id=p_store_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_NOT_APPROVED'; END IF;
  IF (v_fin.delivery_payment_mode='store_prepaid' AND (p_actual_fee IS NULL OR p_actual_fee<0 OR p_actual_fee::text IN ('NaN','Infinity','-Infinity')))
    OR (v_fin.delivery_payment_mode='customer_direct' AND p_actual_fee IS NOT NULL) THEN RAISE EXCEPTION 'DIRECT_ORDER_DISPATCH_INPUT_INVALID'; END IF;
  SELECT * INTO v_dispatch FROM public.direct_order_dispatches WHERE request_id=p_request_id;
  IF FOUND THEN
    IF v_dispatch.delivery_provider IS DISTINCT FROM p_provider OR v_dispatch.grab_tracking_url IS DISTINCT FROM v_url
      OR v_dispatch.actual_grab_fee IS DISTINCT FROM p_actual_fee OR v_dispatch.provider_name IS DISTINCT FROM v_name
      OR v_dispatch.driver_contact IS DISTINCT FROM v_contact THEN RAISE EXCEPTION 'DIRECT_ORDER_CASH_PAYOUT_LOCKED'; END IF;
    RETURN public.direct_order_fulfillment_context(p_request_id);
  END IF;
  IF EXISTS(SELECT 1 FROM public.direct_order_pickup_offers WHERE request_id=p_request_id AND status='proposed') THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_OFFER_PENDING'; END IF;
  SELECT * INTO v_ticket FROM public.direct_delivery_fulfillment_tickets WHERE request_id=p_request_id FOR UPDATE;
  IF v_ticket.version IS DISTINCT FROM p_expected_version THEN RAISE EXCEPTION 'DIRECT_DELIVERY_TICKET_VERSION_CONFLICT'; END IF;
  IF v_ticket.status<>'ready' THEN RAISE EXCEPTION 'DIRECT_DELIVERY_TICKET_TRANSITION_INVALID'; END IF;
  INSERT INTO public.direct_order_dispatches(request_id,restaurant_id,grab_tracking_url,delivery_provider,provider_name,driver_contact,
    customer_delivery_fee,actual_grab_fee,fee_variance,cash_paid_at,delivery_payment_mode,sent_by)
  VALUES(p_request_id,p_store_id,v_url,p_provider,v_name,v_contact,v_fin.delivery_fee_total,p_actual_fee,
    CASE WHEN p_actual_fee IS NULL THEN NULL ELSE v_fin.delivery_fee_total-p_actual_fee END,
    CASE WHEN p_actual_fee IS NULL THEN NULL ELSE now() END,v_fin.delivery_payment_mode,auth.uid());
  UPDATE public.direct_delivery_fulfillment_tickets SET status='dispatched',version=version+1,dispatched_at=now(),updated_by=auth.uid(),updated_at=now() WHERE id=v_ticket.id;
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES
    (auth.uid(),'direct_order_driver_handoff','direct_order_requests',p_request_id,
      jsonb_build_object('provider',p_provider,'provider_name',v_name,'tracking_url',v_url,'ticket_id',v_ticket.id,'actual_fee',p_actual_fee,'delivery_payment_mode',v_fin.delivery_payment_mode));
  INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,metadata)
    VALUES(p_request_id,p_store_id,'system','system','DIRECT_ORDER_DRIVER_HANDOFF',jsonb_build_object('provider',p_provider));
  RETURN public.direct_order_fulfillment_context(p_request_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.direct_order_cashier_complete_pickup(p_store_id uuid,p_request_id uuid,p_expected_version integer)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public,auth,pg_catalog AS $$
DECLARE v_ticket public.direct_delivery_fulfillment_tickets%ROWTYPE; v_result jsonb;
BEGIN
  PERFORM public.direct_order_require_actor(p_store_id,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
  PERFORM 1 FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id AND state='approved' AND fulfillment_method='pickup' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_NOT_ALLOWED'; END IF;
  SELECT * INTO v_ticket FROM public.direct_delivery_fulfillment_tickets WHERE request_id=p_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_DELIVERY_TICKET_NOT_FOUND'; END IF;
  IF v_ticket.status='completed' THEN RETURN to_jsonb(v_ticket)||jsonb_build_object('idempotent',true); END IF;
  IF v_ticket.status<>'ready' THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_NOT_READY'; END IF;
  v_result:=public.direct_delivery_ticket_transition(p_store_id,v_ticket.id,p_expected_version,'completed');
  INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body)
    VALUES(p_request_id,p_store_id,'system','system','DIRECT_ORDER_PICKUP_COMPLETED');
  INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details) VALUES
    (auth.uid(),'direct_order_pickup_completed','direct_order_requests',p_request_id,jsonb_build_object('ticket_id',v_ticket.id));
  RETURN v_result;
END;
$$;

-- Protect legacy callers too. Closing a configured storefront never strands
-- an in-flight request; the settings mutation is serialized against new submit.
CREATE OR REPLACE FUNCTION public.direct_order_guard_storefront_disable()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
  IF OLD.is_enabled AND NOT NEW.is_enabled AND EXISTS(
    SELECT 1 FROM public.direct_order_requests r LEFT JOIN public.direct_delivery_fulfillment_tickets t ON t.request_id=r.id
    WHERE r.restaurant_id=OLD.restaurant_id AND (r.state IN ('awaiting_quote','quoted','awaiting_payment_review')
      OR (r.state='approved' AND (t.id IS NULL OR t.status NOT IN ('completed','cancelled'))))
  ) THEN RAISE EXCEPTION 'DIRECT_ORDER_ACTIVE_REQUESTS_EXIST'; END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER direct_order_guard_storefront_disable BEFORE UPDATE OF is_enabled ON public.direct_order_storefronts
FOR EACH ROW EXECUTE FUNCTION public.direct_order_guard_storefront_disable();

CREATE OR REPLACE FUNCTION public.direct_order_guard_dispatch_method()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE v_method text; v_status text;
BEGIN
  SELECT fulfillment_method INTO v_method FROM public.direct_order_requests WHERE id=NEW.request_id FOR UPDATE;
  IF v_method<>'delivery' THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_NOT_ALLOWED'; END IF;
  IF EXISTS(SELECT 1 FROM public.direct_order_pickup_offers WHERE request_id=NEW.request_id AND status='proposed') THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_OFFER_PENDING'; END IF;
  SELECT status INTO v_status FROM public.direct_delivery_fulfillment_tickets WHERE request_id=NEW.request_id FOR UPDATE;
  IF v_status IS NULL OR v_status NOT IN ('ready','dispatched') THEN RAISE EXCEPTION 'DIRECT_DELIVERY_TICKET_TRANSITION_INVALID'; END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER direct_order_guard_dispatch_method BEFORE INSERT OR UPDATE ON public.direct_order_dispatches
FOR EACH ROW EXECUTE FUNCTION public.direct_order_guard_dispatch_method();

-- Patch only narrow anchors in the latest effective functions, preserving all
-- intervening photo-review/payment/receipt/operational-hour changes.
DO $patch$
DECLARE v_def text; v_signature regprocedure; v_old text; v_new text;
BEGIN
  v_signature:='public.direct_order_approve_payment(uuid,uuid,numeric,text)'::regprocedure;
  v_def:=pg_get_functiondef(v_signature);
  v_old:='''serving'', NULL,';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_FALLBACK_ANCHOR_DRIFT'; END IF;
  EXECUTE replace(v_def,v_old,'''serving'', v_request.diner_count,');

  v_signature:='public.direct_order_staff_quote(uuid,uuid,numeric,text)'::regprocedure;
  v_def:=pg_get_functiondef(v_signature);
  v_old:='  SELECT * INTO v_storefront';
  v_new:=E'  IF v_request.fulfillment_method = ''pickup'' AND p_delivery_fee_total <> 0 THEN\n    RAISE EXCEPTION ''DIRECT_ORDER_PICKUP_FEE_INVALID'';\n  END IF;\n  IF v_request.fulfillment_method = ''pickup'' AND v_request.state = ''quoted'' AND EXISTS (SELECT 1 FROM public.direct_order_quotes WHERE request_id=p_request_id AND status IN (''active'',''locked'') AND delivery_fee_total>0) THEN\n    RAISE EXCEPTION ''DIRECT_ORDER_PAYMENT_PROOF_REQUIRED'';\n  END IF;\n\n'||v_old;
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_FALLBACK_ANCHOR_DRIFT'; END IF;
  EXECUTE replace(v_def,v_old,v_new);

  v_signature:='public.direct_delivery_ticket_transition(uuid,uuid,integer,text)'::regprocedure;
  v_def:=pg_get_functiondef(v_signature);
  v_def:=replace(v_def,'  SELECT * INTO v_ticket',E'  PERFORM 1 FROM public.direct_order_requests WHERE id=(SELECT request_id FROM public.direct_delivery_fulfillment_tickets WHERE id=p_ticket_id AND restaurant_id=p_store_id) FOR UPDATE;\n  SELECT * INTO v_ticket');
  IF strpos(v_def,'fulfillment_type=''delivery''')=0
     OR strpos(v_def,'fulfillment_type=''pickup''')=0 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_FALLBACK_ANCHOR_DRIFT';
  END IF;
  v_def:=replace(v_def,'fulfillment_type=''delivery''','fulfillment_method=''delivery''');
  EXECUTE replace(v_def,'fulfillment_type=''pickup''','fulfillment_method=''pickup''');

  -- Both older dispatch entry points accept provider-neutral HTTPS links.
  FOREACH v_signature IN ARRAY ARRAY[
    'public.direct_order_set_dispatch(uuid,uuid,text,numeric)'::regprocedure,
    'public.direct_order_set_dispatch_with_payment_mode(uuid,uuid,text,numeric)'::regprocedure
  ] LOOP
    v_def:=pg_get_functiondef(v_signature);
    v_old:=E'lower(COALESCE(p_grab_tracking_url, '''')) !~\n       ''^(https://([[:alnum:]-]+[.])*grab[.]com([/:?#]|$)|https://grab[.]onelink[.]me([/:?#]|$))''';
    IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_FALLBACK_ANCHOR_DRIFT'; END IF;
    EXECUTE replace(v_def,v_old,'(p_grab_tracking_url IS NULL OR NOT public.direct_order_tracking_url_valid(p_grab_tracking_url))');
  END LOOP;

  -- Older clients expect a complete URL whenever dispatch is non-null.
  v_signature:='public.direct_order_public_status(uuid,text,uuid)'::regprocedure;
  v_def:=pg_get_functiondef(v_signature);
  v_old:='WHERE dispatch.request_id = v_request.id';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_FALLBACK_ANCHOR_DRIFT'; END IF;
  EXECUTE replace(v_def,v_old,v_old||' AND dispatch.grab_tracking_url IS NOT NULL');

  -- The versioned customer list displays the currently agreed collection method.
  v_signature:='public.direct_order_public_orders_v3(uuid,text,integer)'::regprocedure;
  v_def:=pg_get_functiondef(v_signature);
  v_old:='request.fulfillment_type';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_FALLBACK_ANCHOR_DRIFT'; END IF;
  EXECUTE replace(v_def,v_old,'request.fulfillment_method');

  -- Keep pending refunds visible after fulfillment completion and across days.
  v_signature:='public.direct_order_staff_list_v2(uuid,text[],integer)'::regprocedure;
  v_def:=pg_get_functiondef(v_signature);
  v_old:='OR ticket.status NOT IN (''completed'', ''cancelled'')';
  v_new:=v_old||' OR EXISTS (SELECT 1 FROM public.direct_order_pickup_offers po JOIN public.direct_order_financials pf ON pf.request_id=po.request_id WHERE po.request_id=request_row.id AND po.status=''accepted'' AND po.adjustment_id IS NULL AND pf.delivery_fee_total>0)';
  IF strpos(v_def,v_old)=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_FALLBACK_ANCHOR_DRIFT'; END IF;
  EXECUTE replace(v_def,v_old,v_new);
END;
$patch$;

CREATE OR REPLACE FUNCTION public.direct_delivery_ticket_list_v3(p_store_id uuid,p_statuses text[] DEFAULT NULL,p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v_base jsonb;
BEGIN
  v_base:=public.direct_delivery_ticket_list(p_store_id,p_statuses,NULL,NULL,p_limit);
  RETURN COALESCE((SELECT jsonb_agg(x.value || jsonb_build_object('delivery',public.direct_order_fulfillment_context((x.value->>'request_id')::uuid)) ORDER BY x.n)
    FROM jsonb_array_elements(v_base) WITH ORDINALITY x(value,n)), '[]'::jsonb);
END;
$$;

CREATE OR REPLACE FUNCTION public.direct_order_analytics_v3(p_store_id uuid,p_from_date date,p_to_date date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE v_base jsonb; v_refunds numeric;
BEGIN
  v_base:=public.direct_order_analytics(p_store_id,p_from_date,p_to_date);
  SELECT COALESCE(sum(a.amount),0) INTO v_refunds FROM public.payment_adjustments a JOIN public.direct_order_financials f ON f.payment_id=a.payment_id
    WHERE f.restaurant_id=p_store_id AND (f.approved_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date BETWEEN p_from_date AND p_to_date;
  RETURN jsonb_set(v_base,'{summary}',(v_base->'summary')||jsonb_build_object('refund_total',v_refunds,
    'net_sales',COALESCE((v_base->'summary'->>'gross_sales')::numeric,0)-v_refunds,
    'delivery_cost',v_base->'summary'->'grab_cost'));
END;
$$;

CREATE OR REPLACE FUNCTION public.direct_order_enrich_print_fulfillment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE v_context jsonb;
BEGIN
  SELECT public.direct_order_fulfillment_context(f.request_id) INTO v_context
  FROM public.direct_order_financials f WHERE f.order_id=NEW.order_id AND f.restaurant_id=NEW.restaurant_id;
  IF v_context IS NOT NULL THEN NEW.payload:=NEW.payload||jsonb_build_object('diner_count',v_context->'diner_count','fulfillment_method',v_context->'method','refunded_total',v_context->'refunded_total'); END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER zz_direct_order_enrich_print_fulfillment BEFORE INSERT ON public.print_jobs
FOR EACH ROW EXECUTE FUNCTION public.direct_order_enrich_print_fulfillment();

-- Explicit privilege inventory: public mutations are service-only; staff RPCs
-- always validate actor/store access. Internal trigger helpers are not RPCs.
DO $privileges$
DECLARE v_sig regprocedure;
BEGIN
  FOREACH v_sig IN ARRAY ARRAY[
    'public.direct_order_public_submit_v3(uuid,text,uuid,jsonb)'::regprocedure,
    'public.direct_order_public_status_v3(uuid,text,uuid)'::regprocedure,
    'public.direct_order_public_resume_storefront(uuid,text)'::regprocedure,
    'public.direct_order_public_decide_pickup(uuid,text,uuid,uuid,boolean,boolean)'::regprocedure
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',v_sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',v_sig);
  END LOOP;
  FOREACH v_sig IN ARRAY ARRAY[
    'public.direct_order_staff_detail_v3(uuid,uuid)'::regprocedure,
    'public.direct_order_staff_set_diner_count(uuid,uuid,integer,integer)'::regprocedure,
    'public.direct_order_staff_offer_pickup(uuid,uuid,integer,text)'::regprocedure,
    'public.direct_order_staff_record_pickup_refund(uuid,uuid,uuid,text)'::regprocedure,
    'public.direct_order_set_dispatch_v3(uuid,uuid,integer,text,text,numeric,text,text)'::regprocedure,
    'public.direct_order_cashier_complete_pickup(uuid,uuid,integer)'::regprocedure,
    'public.direct_delivery_ticket_list_v3(uuid,text[],integer)'::regprocedure,
    'public.direct_order_analytics_v3(uuid,date,date)'::regprocedure
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon',v_sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated,service_role',v_sig);
  END LOOP;
  FOREACH v_sig IN ARRAY ARRAY[
    'public.direct_order_guard_storefront_disable()'::regprocedure,
    'public.direct_order_guard_dispatch_method()'::regprocedure,
    'public.direct_order_enrich_print_fulfillment()'::regprocedure
  ] LOOP EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',v_sig); END LOOP;
END;
$privileges$;

DO $verify$
BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='public.direct_order_pickup_offers'::regclass AND relrowsecurity)
    OR has_function_privilege('anon','public.direct_order_public_decide_pickup(uuid,text,uuid,uuid,boolean,boolean)','EXECUTE')
    OR has_function_privilege('authenticated','public.direct_order_fulfillment_context(uuid)','EXECUTE')
    OR NOT public.direct_order_tracking_url_valid('https://be.example/track/abc')
    OR public.direct_order_tracking_url_valid('https://user:pass@example.com')
    OR strpos(pg_get_functiondef('public.direct_order_approve_payment(uuid,uuid,numeric,text)'::regprocedure),'v_request.diner_count')=0
  THEN RAISE EXCEPTION 'DIRECT_ORDER_FALLBACK_VERIFICATION_FAILED'; END IF;
END;
$verify$;
COMMIT;
