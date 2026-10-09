-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';

ALTER TABLE public.direct_order_quotes ADD COLUMN amount_finalized_at timestamptz;
UPDATE public.direct_order_quotes SET amount_finalized_at=created_at
WHERE status IN ('active','locked');

ALTER FUNCTION public.direct_order_staff_quote(uuid,uuid,numeric,text)
RENAME TO direct_order_staff_quote_before_final_amount;
REVOKE ALL ON FUNCTION public.direct_order_staff_quote_before_final_amount(uuid,uuid,numeric,text)
FROM PUBLIC,anon,authenticated;

CREATE OR REPLACE FUNCTION public.direct_order_staff_quote_with_payment_mode(
 p_store_id uuid,p_request_id uuid,p_delivery_fee_total numeric,
 p_cashier_note text DEFAULT NULL,p_delivery_payment_mode text DEFAULT 'customer_direct'
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE r public.direct_order_requests%ROWTYPE; q public.direct_order_quotes%ROWTYPE;
 v jsonb; mode text; fee numeric;
BEGIN
 PERFORM public.direct_order_require_actor(p_store_id,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 SELECT * INTO r FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_FOUND'; END IF;
 IF p_delivery_payment_mode NOT IN ('customer_direct','store_prepaid') OR p_delivery_fee_total IS NULL
 OR p_delivery_fee_total<0 OR p_delivery_fee_total<>trunc(p_delivery_fee_total)
 OR p_delivery_fee_total::text IN ('NaN','Infinity','-Infinity') OR length(COALESCE(p_cashier_note,''))>500 THEN
  RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_INPUT_INVALID';
 END IF;
 mode:=CASE WHEN r.fulfillment_method='pickup' THEN 'customer_direct'
  WHEN r.delivery_fee_deferred THEN 'store_prepaid' ELSE p_delivery_payment_mode END;
 fee:=CASE WHEN r.fulfillment_method='pickup' OR r.delivery_fee_deferred THEN 0 ELSE p_delivery_fee_total END;
 IF mode='customer_direct' AND fee<>0 THEN RAISE EXCEPTION 'DIRECT_ORDER_QUOTE_INPUT_INVALID'; END IF;
 SELECT * INTO q FROM public.direct_order_quotes WHERE request_id=r.id AND status IN ('active','locked') ORDER BY version DESC LIMIT 1;
 IF FOUND THEN
  IF r.state NOT IN ('quoted','awaiting_payment_review','approved') THEN RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_NOT_QUOTABLE'; END IF;
  IF q.delivery_fee_total IS DISTINCT FROM fee OR (r.fulfillment_method<>'pickup' AND q.delivery_payment_mode IS DISTINCT FROM mode) THEN
   RAISE EXCEPTION 'DIRECT_ORDER_FINAL_AMOUNT_LOCKED';
  END IF;
  RETURN to_jsonb(q)-ARRAY['restaurant_id','created_by'];
 END IF;
 v:=public.direct_order_staff_quote_before_final_amount(p_store_id,r.id,fee,p_cashier_note);
 UPDATE public.direct_order_quotes SET delivery_payment_mode=mode,amount_finalized_at=now()
 WHERE id=(v->>'id')::uuid RETURNING * INTO q;
 UPDATE public.direct_order_messages SET metadata=metadata||jsonb_build_object('delivery_payment_mode',mode)
 WHERE request_id=r.id AND message_type='quote' AND metadata->>'quote_id'=q.id::text;
 RETURN to_jsonb(q)-ARRAY['restaurant_id','created_by'];
END;
$$;
CREATE FUNCTION public.direct_order_staff_quote(p_store_id uuid,p_request_id uuid,p_delivery_fee_total numeric,p_cashier_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT public.direct_order_staff_quote_with_payment_mode($1,$2,$3,$4,'store_prepaid');
$$;
REVOKE ALL ON FUNCTION public.direct_order_staff_quote(uuid,uuid,numeric,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_staff_quote(uuid,uuid,numeric,text) TO authenticated,service_role;

CREATE FUNCTION public.direct_order_preserve_final_amount() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
BEGIN
 IF TG_OP='DELETE' THEN
  IF OLD.amount_finalized_at IS NOT NULL THEN RAISE EXCEPTION 'DIRECT_ORDER_FINAL_AMOUNT_LOCKED'; END IF;
  RETURN OLD;
 END IF;
 IF OLD.amount_finalized_at IS NOT NULL AND (
  (to_jsonb(NEW)-ARRAY['status','locked_at','expires_at','cashier_note']) IS DISTINCT FROM
  (to_jsonb(OLD)-ARRAY['status','locked_at','expires_at','cashier_note'])
  OR NEW.status='superseded' AND OLD.status IN ('active','locked')) THEN
  RAISE EXCEPTION 'DIRECT_ORDER_FINAL_AMOUNT_LOCKED';
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER direct_order_preserve_final_amount BEFORE UPDATE OR DELETE ON public.direct_order_quotes
FOR EACH ROW EXECUTE FUNCTION public.direct_order_preserve_final_amount();
CREATE FUNCTION public.direct_order_preserve_quoted_items() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF EXISTS(SELECT 1 FROM public.direct_order_quotes WHERE
  request_id IN (CASE WHEN TG_OP<>'INSERT' THEN OLD.request_id END, CASE WHEN TG_OP<>'DELETE' THEN NEW.request_id END)
  AND amount_finalized_at IS NOT NULL AND status IN ('active','locked')) THEN
  RAISE EXCEPTION 'DIRECT_ORDER_FINAL_AMOUNT_LOCKED';
 END IF;
 IF TG_OP='DELETE' THEN RETURN OLD; END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER direct_order_preserve_quoted_items BEFORE INSERT OR UPDATE OR DELETE ON public.direct_order_request_items
FOR EACH ROW EXECUTE FUNCTION public.direct_order_preserve_quoted_items();

-- Preserve existing quote/proof IDs. Finalized quotes are governed by order
-- lifecycle rather than the old display TTL; legacy endpoints follow the same rule.
DO $proof_ttl$
DECLARE signature text; d text; patched text;
BEGIN
 FOREACH signature IN ARRAY ARRAY[
 'public.direct_order_public_commit_proof_v2(uuid,text,uuid,uuid,text,uuid)',
 'public.direct_order_public_commit_proof(uuid,text,uuid,text)',
 'public.direct_order_approve_payment(uuid,uuid,numeric,text)'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO d;
  patched:=replace(d,'v_quote.expires_at <= now()','(v_quote.amount_finalized_at IS NULL AND v_quote.expires_at <= now())');
  patched:=replace(patched,'quote_row.expires_at > now()','(quote_row.amount_finalized_at IS NOT NULL OR quote_row.expires_at > now())');
  IF patched=d AND signature<>'public.direct_order_approve_payment(uuid,uuid,numeric,text)' THEN RAISE EXCEPTION 'DIRECT_ORDER_FINAL_AMOUNT_PATCH_DRIFT: %',signature; END IF;
  EXECUTE patched;
 END LOOP;
END;
$proof_ttl$;

-- Keep legacy status payloads unchanged during the DB -> Edge -> client rollout.
-- Status reads refresh session activity, so this new entry point is VOLATILE.
CREATE FUNCTION public.direct_order_public_status_v6(p_session_id uuid,p_secret_hash text,p_request_id uuid)
RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE v jsonb; finalized timestamptz;
BEGIN
 v:=public.direct_order_public_status_v5($1,$2,$3);
 IF jsonb_typeof(v->'quote')='object' THEN
  SELECT amount_finalized_at INTO finalized FROM public.direct_order_quotes WHERE id=(v->'quote'->>'id')::uuid;
  v:=jsonb_set(v,'{quote}',v->'quote'||jsonb_build_object('amount_finalized_at',finalized));
 END IF;
 RETURN v;
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_public_status_v6(uuid,text,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_status_v6(uuid,text,uuid) TO service_role;

CREATE TABLE public.direct_order_access_keys(
 request_id uuid NOT NULL REFERENCES public.direct_order_requests(id) ON DELETE CASCADE,
 key_hash text NOT NULL CHECK(key_hash ~ '^[a-f0-9]{64}$'),
 created_at timestamptz NOT NULL DEFAULT now(),revoked_at timestamptz,
 PRIMARY KEY(request_id,key_hash)
);
ALTER TABLE public.direct_order_access_keys ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.direct_order_access_keys FROM PUBLIC,anon,authenticated;
GRANT ALL ON public.direct_order_access_keys TO service_role;

CREATE FUNCTION public.direct_order_access_is_open(p_request_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT COALESCE((SELECT r.support_closed_at IS NULL AND r.pii_purged_at IS NULL
  AND (r.state NOT IN ('rejected','expired') OR EXISTS(SELECT 1 FROM public.direct_order_payment_receipts WHERE request_id=r.id))
  AND (NOT EXISTS(SELECT 1 FROM public.direct_delivery_fulfillment_tickets t WHERE t.request_id=r.id AND t.status='completed')
   OR r.fulfillment_method='pickup' AND (
    EXISTS(SELECT 1 FROM public.direct_order_pickup_offers o JOIN public.direct_order_financials f ON f.request_id=o.request_id WHERE o.request_id=r.id AND o.status='accepted' AND o.adjustment_id IS NULL AND f.delivery_fee_total>0)
    OR public.direct_order_supplemental_delivery_refund_due(r.id)>0))
 FROM public.direct_order_requests r WHERE r.id=p_request_id),false);
$$;
CREATE FUNCTION public.direct_order_issue_access(p_session_id uuid,p_secret_hash text,p_request_id uuid,p_key_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE s public.direct_order_sessions%ROWTYPE;
BEGIN
 s:=public.direct_order_validate_session(p_session_id,p_secret_hash);
 IF p_key_hash IS NULL OR p_key_hash !~ '^[a-f0-9]{64}$' OR NOT EXISTS(
  SELECT 1 FROM public.direct_order_requests WHERE id=p_request_id AND session_id=s.id AND restaurant_id=s.restaurant_id
 ) THEN RAISE EXCEPTION 'DIRECT_ORDER_UNAVAILABLE'; END IF;
 IF NOT public.direct_order_access_is_open(p_request_id) THEN RAISE EXCEPTION 'DIRECT_ORDER_ORDER_CLOSED'; END IF;
 INSERT INTO public.direct_order_access_keys(request_id,key_hash) VALUES(p_request_id,p_key_hash) ON CONFLICT DO NOTHING;
 RETURN jsonb_build_object('request_id',p_request_id);
END;
$$;
CREATE FUNCTION public.direct_order_public_submit_with_access(p_session_id uuid,p_secret_hash text,p_client_request_id uuid,p_payload jsonb,p_key_hash text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE v jsonb;
BEGIN
 v:=public.direct_order_public_submit_v3($1,$2,$3,$4);
 PERFORM public.direct_order_issue_access($1,$2,(v->>'request_id')::uuid,$5);
 RETURN v;
END;
$$;
CREATE FUNCTION public.direct_order_resolve_access(p_request_id uuid,p_key_hash text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE s public.direct_order_sessions%ROWTYPE; slug text;
BEGIN
 SELECT session_row.* INTO s
 FROM public.direct_order_access_keys k
 JOIN public.direct_order_requests r ON r.id=k.request_id
 JOIN public.direct_order_sessions session_row ON session_row.id=r.session_id
 JOIN public.direct_order_storefronts storefront ON storefront.restaurant_id=r.restaurant_id
 WHERE k.request_id=p_request_id AND k.key_hash=p_key_hash AND session_row.revoked_at IS NULL;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_ORDER_UNAVAILABLE'; END IF;
 IF NOT public.direct_order_access_is_open(p_request_id) THEN RAISE EXCEPTION 'DIRECT_ORDER_ORDER_CLOSED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_access_keys WHERE request_id=p_request_id AND key_hash=p_key_hash AND revoked_at IS NULL) THEN
  RAISE EXCEPTION 'DIRECT_ORDER_UNAVAILABLE'; END IF;
 SELECT public_slug INTO slug FROM public.direct_order_storefronts WHERE restaurant_id=s.restaurant_id;
 -- A valid unfinished order survives the browser session's original TTL.
 UPDATE public.direct_order_sessions SET expires_at=greatest(expires_at,now()+interval '30 days'),last_seen_at=now() WHERE id=s.id;
 RETURN jsonb_build_object('session_id',s.id,'secret_hash',s.secret_hash,'slug',slug);
END;
$$;
CREATE FUNCTION public.direct_order_revoke_finished_access() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE request_uuid uuid;
BEGIN
 IF TG_TABLE_NAME='direct_order_requests' THEN request_uuid:=NEW.id;
 ELSE request_uuid:=NEW.request_id; END IF;
 IF NOT public.direct_order_access_is_open(request_uuid) THEN
  UPDATE public.direct_order_access_keys SET revoked_at=COALESCE(revoked_at,now()) WHERE request_id=request_uuid;
 END IF;
 RETURN NEW;
END;
$$;
CREATE TRIGGER direct_order_revoke_finished_request AFTER UPDATE OF state,support_closed_at,support_version ON public.direct_order_requests
FOR EACH ROW EXECUTE FUNCTION public.direct_order_revoke_finished_access();
CREATE TRIGGER direct_order_revoke_finished_fulfillment AFTER UPDATE OF status ON public.direct_delivery_fulfillment_tickets
FOR EACH ROW EXECUTE FUNCTION public.direct_order_revoke_finished_access();
CREATE TRIGGER direct_order_revoke_refunded_pickup AFTER UPDATE OF adjustment_id ON public.direct_order_pickup_offers
FOR EACH ROW EXECUTE FUNCTION public.direct_order_revoke_finished_access();

CREATE FUNCTION public.direct_order_close_unfunded_cancellation() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF NEW.state IN ('cancelled','rejected','expired') AND NOT EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=NEW.id) AND NOT EXISTS(SELECT 1 FROM public.direct_order_payment_receipts WHERE request_id=NEW.id) THEN NEW.support_closed_at:=COALESCE(NEW.support_closed_at,now()); END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER direct_order_close_unfunded_cancellation BEFORE UPDATE OF state ON public.direct_order_requests FOR EACH ROW EXECUTE FUNCTION public.direct_order_close_unfunded_cancellation();
UPDATE public.direct_order_requests SET support_closed_at=now() WHERE state IN ('cancelled','rejected','expired') AND support_closed_at IS NULL AND NOT EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=direct_order_requests.id) AND NOT EXISTS(SELECT 1 FROM public.direct_order_payment_receipts WHERE request_id=direct_order_requests.id);
DO $access_permissions$
DECLARE signature regprocedure;
BEGIN
 FOREACH signature IN ARRAY ARRAY[
 'public.direct_order_access_is_open(uuid)'::regprocedure,
 'public.direct_order_issue_access(uuid,text,uuid,text)'::regprocedure,
 'public.direct_order_public_submit_with_access(uuid,text,uuid,jsonb,text)'::regprocedure,
 'public.direct_order_resolve_access(uuid,text)'::regprocedure] LOOP
  EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',signature);
  EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role',signature);
 END LOOP;
END;
$access_permissions$;

-- Open customer access must not lose its address/chat through age-only cleanup.
DO $access_retention$
DECLARE signature text; d text;
BEGIN
 FOREACH signature IN ARRAY ARRAY['public.direct_order_cleanup_candidates(integer)','public.direct_order_cleanup_expired_pii(uuid[])'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO d;
  IF strpos(d,'request_row.pii_purged_at IS NULL')=0 THEN RAISE EXCEPTION 'DIRECT_ORDER_RETENTION_PATCH_DRIFT'; END IF;
  EXECUTE replace(d,'request_row.pii_purged_at IS NULL','request_row.pii_purged_at IS NULL AND NOT public.direct_order_access_is_open(request_row.id)');
 END LOOP;
END;
$access_retention$;
DO $verify$
BEGIN
 IF has_function_privilege('anon','public.direct_order_resolve_access(uuid,text)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_staff_quote_before_final_amount(uuid,uuid,numeric,text)','EXECUTE')
 OR has_table_privilege('authenticated','public.direct_order_access_keys','SELECT') THEN RAISE EXCEPTION 'DIRECT_ORDER_ACCESS_PERMISSION_DRIFT'; END IF;
END;
$verify$;

ALTER TABLE public.direct_order_push_devices ADD COLUMN request_scope_id uuid REFERENCES public.direct_order_requests(id);
DROP INDEX public.direct_order_push_session_token;
CREATE UNIQUE INDEX direct_order_push_session_token ON public.direct_order_push_devices(session_id,md5(push_token),COALESCE(request_scope_id,'00000000-0000-0000-0000-000000000000'::uuid));
CREATE FUNCTION public.direct_order_public_push_subscription_scoped(p_session_id uuid,p_secret_hash text,p_device_id uuid,p_token text,p_locale text,p_enabled boolean,p_request_scope_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 PERFORM public.direct_order_validate_session(p_session_id,p_secret_hash);
 IF p_request_scope_id IS NULL THEN RETURN public.direct_order_public_push_subscription($1,$2,$3,$4,$5,$6); END IF;
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_requests WHERE id=p_request_scope_id AND session_id=p_session_id) OR NOT public.direct_order_access_is_open(p_request_scope_id) THEN RAISE EXCEPTION 'DIRECT_ORDER_UNAVAILABLE'; END IF;
 IF p_device_id IS NULL OR p_enabled IS NULL OR p_locale IS NULL OR p_locale NOT IN ('ko','vi','en') OR (p_enabled AND (p_token IS NULL OR char_length(p_token) NOT BETWEEN 16 AND 2048 OR p_token !~ '^[A-Za-z0-9_:-]+$')) THEN RAISE EXCEPTION 'DIRECT_ORDER_PUSH_INPUT_INVALID'; END IF;
 PERFORM 1 FROM public.direct_order_sessions WHERE id=p_session_id FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.direct_order_push_devices WHERE session_id=p_session_id AND device_id=p_device_id AND request_scope_id IS DISTINCT FROM p_request_scope_id) THEN RAISE EXCEPTION 'DIRECT_ORDER_UNAVAILABLE'; END IF;
 IF NOT p_enabled THEN UPDATE public.direct_order_push_devices SET enabled=false,updated_at=now() WHERE session_id=p_session_id AND device_id=p_device_id AND request_scope_id=p_request_scope_id;
 ELSE
  IF NOT EXISTS(SELECT 1 FROM public.direct_order_push_devices WHERE session_id=p_session_id AND device_id=p_device_id) AND (SELECT count(*) FROM public.direct_order_push_devices WHERE session_id=p_session_id AND request_scope_id=p_request_scope_id)>=5 THEN RAISE EXCEPTION 'DIRECT_ORDER_PUSH_DEVICE_LIMIT'; END IF;
  DELETE FROM public.direct_order_push_devices WHERE session_id=p_session_id AND request_scope_id=p_request_scope_id AND md5(push_token)=md5(p_token) AND device_id<>p_device_id;
  INSERT INTO public.direct_order_push_devices(session_id,device_id,push_token,locale,enabled,request_scope_id) VALUES($1,$3,$4,$5,true,$7)
  ON CONFLICT(session_id,device_id) DO UPDATE SET push_token=EXCLUDED.push_token,locale=EXCLUDED.locale,enabled=true,updated_at=now();
 END IF;
 RETURN jsonb_build_object('enabled',p_enabled);
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_public_push_subscription_scoped(uuid,text,uuid,text,text,boolean,uuid) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_push_subscription_scoped(uuid,text,uuid,text,text,boolean,uuid) TO service_role;
DO $push_scope$
DECLARE d text; patched text; signature text;
BEGIN
 FOREACH signature IN ARRAY ARRAY['public.direct_order_notify_payment(uuid,uuid)','public.direct_order_enqueue_customer_event(uuid,text)'] LOOP
  SELECT pg_get_functiondef(signature::regprocedure) INTO d;
  patched:=replace(d,'d.session_id=r.session_id AND d.enabled','d.session_id=r.session_id AND (d.request_scope_id IS NULL OR d.request_scope_id=r.id) AND d.enabled');
  patched:=replace(patched,'d.session_id=v_request.session_id AND d.enabled','d.session_id=v_request.session_id AND (d.request_scope_id IS NULL OR d.request_scope_id=v_request.id) AND d.enabled');
  IF patched=d THEN RAISE EXCEPTION 'DIRECT_ORDER_PUSH_SCOPE_PATCH_DRIFT'; END IF;
  EXECUTE patched;
 END LOOP;
 SELECT pg_get_functiondef('public.claim_direct_order_push_deliveries(integer)'::regprocedure) INTO d;
 d:=replace(d,'q.status=''active'' AND q.expires_at>now()','q.status=''active'' AND (q.amount_finalized_at IS NOT NULL OR q.expires_at>now())');
 patched:=replace(d,'NOT d.enabled OR','(d.request_scope_id IS NOT NULL AND d.request_scope_id<>r.id) OR NOT d.enabled OR');
 IF patched=d THEN RAISE EXCEPTION 'DIRECT_ORDER_PUSH_SCOPE_PATCH_DRIFT'; END IF;
 EXECUTE patched;
END;
$push_scope$;
COMMIT;
