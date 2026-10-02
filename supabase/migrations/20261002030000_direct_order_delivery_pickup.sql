-- Add customer-selected delivery/pickup to the existing direct-order domain.
-- production-gate: self-verifying
BEGIN;
ALTER TABLE public.direct_order_requests ADD COLUMN fulfillment_type text NOT NULL
 DEFAULT 'delivery' CHECK (fulfillment_type IN ('delivery','pickup'));
-- Contact remains protected by the existing RLS/PII lifecycle. Pickup has no address.
ALTER TABLE public.direct_order_request_addresses
 ALTER COLUMN formatted_address DROP NOT NULL, ALTER COLUMN detail_address DROP NOT NULL,
 DROP CONSTRAINT direct_order_request_addresses_address_source_check,
 DROP CONSTRAINT direct_order_address_location_mode_valid;
ALTER TABLE public.direct_order_request_addresses
 ADD CONSTRAINT direct_order_request_addresses_address_source_check
 CHECK(address_source IN ('manual','search','map_pin','pickup')),
 ADD CONSTRAINT direct_order_address_location_mode_valid CHECK (
  (address_source='pickup' AND formatted_address IS NULL AND detail_address IS NULL
   AND latitude IS NULL AND longitude IS NULL AND google_place_id IS NULL AND district IS NULL AND ward IS NULL AND NOT location_verified)
  OR (address_source='manual' AND formatted_address IS NOT NULL AND detail_address IS NOT NULL
   AND latitude IS NULL AND longitude IS NULL AND google_place_id IS NULL AND NOT location_verified)
  OR (address_source IN ('search','map_pin') AND formatted_address IS NOT NULL AND detail_address IS NOT NULL
   AND latitude IS NOT NULL AND longitude IS NOT NULL));
ALTER TABLE public.direct_order_quotes DROP CONSTRAINT direct_order_quotes_delivery_payment_mode_check;
ALTER TABLE public.direct_order_quotes ADD CONSTRAINT direct_order_quotes_delivery_payment_mode_check
 CHECK(delivery_payment_mode IN ('customer_direct','store_prepaid','not_applicable'));
ALTER TABLE public.direct_order_quotes ADD CONSTRAINT direct_order_pickup_quote_zero_fee CHECK(delivery_payment_mode<>'not_applicable' OR delivery_fee_total=0);
ALTER TABLE public.direct_order_financials DROP CONSTRAINT direct_order_financials_delivery_payment_mode_check;
ALTER TABLE public.direct_order_financials ADD CONSTRAINT direct_order_financials_delivery_payment_mode_check
 CHECK(delivery_payment_mode IN ('customer_direct','store_prepaid','not_applicable'));
ALTER TABLE public.direct_order_financials ADD CONSTRAINT direct_order_pickup_financial_zero_fee CHECK(delivery_payment_mode<>'not_applicable' OR delivery_fee_total=0);

CREATE FUNCTION public.guard_direct_order_fulfillment_type() RETURNS trigger
LANGUAGE plpgsql SET search_path=public,pg_catalog AS $$
BEGIN
 IF NEW.fulfillment_type IS DISTINCT FROM OLD.fulfillment_type THEN
  RAISE EXCEPTION 'DIRECT_ORDER_FULFILLMENT_TYPE_LOCKED';
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.guard_direct_order_fulfillment_type() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER direct_order_fulfillment_type_immutable BEFORE UPDATE OF fulfillment_type
 ON public.direct_order_requests FOR EACH ROW EXECUTE FUNCTION public.guard_direct_order_fulfillment_type();

-- Checked edits retain later tax, concurrency, printer and payment fixes.
CREATE FUNCTION pg_temp.direct_pickup_patch(signature text, old_text text, new_text text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE definition text;
BEGIN
 definition := pg_get_functiondef(to_regprocedure(signature));
 IF definition IS NULL OR (length(definition)-length(replace(definition,old_text,'')))/length(old_text) <> 1 THEN
  RAISE EXCEPTION 'DIRECT_PICKUP_MIGRATION_ANCHOR_MISSING:%',signature;
 END IF;
 definition := replace(definition,old_text,new_text);
 EXECUTE definition;
END $$;


DO $$ DECLARE definition text; BEGIN
 definition:=pg_get_functiondef('public.direct_order_public_submit(uuid,text,uuid,jsonb)'::regprocedure);
 definition:=replace(definition,'FUNCTION public.direct_order_public_submit(', 'FUNCTION public.direct_order_public_submit_v2(');
 EXECUTE definition;
END $$;

SELECT pg_temp.direct_pickup_patch('public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)', $old$  v_address jsonb;$old$, $new$  v_address jsonb;
  v_type text := p_payload->>'fulfillment_type';$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)', $old$  v_session := public.direct_order_validate_session($old$, $new$  IF v_type IS NULL OR v_type NOT IN ('delivery','pickup') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
  END IF;
  v_session := public.direct_order_validate_session($new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)', $old$    RETURN jsonb_build_object(
      'request_id', v_existing.id,$old$, $new$    IF v_existing.fulfillment_type <> v_type THEN
      RAISE EXCEPTION 'DIRECT_ORDER_FULFILLMENT_TYPE_LOCKED';
    END IF;
    RETURN jsonb_build_object(
      'request_id', v_existing.id,$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)', $old$     OR char_length(btrim(COALESCE(v_address->>'formatted_address', ''))) NOT BETWEEN 3 AND 500
     OR char_length(btrim(COALESCE(v_address->>'detail_address', ''))) NOT BETWEEN 1 AND 300$old$, $new$     OR (v_type='delivery' AND (char_length(btrim(COALESCE(v_address->>'formatted_address', ''))) NOT BETWEEN 3 AND 500
     OR char_length(btrim(COALESCE(v_address->>'detail_address', ''))) NOT BETWEEN 1 AND 300))$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)', $old$  IF v_address->>'address_source' = 'manual' THEN$old$, $new$  IF v_type='pickup' THEN
    IF v_address->>'address_source' IS DISTINCT FROM 'pickup'
       OR v_address->>'formatted_address' IS NOT NULL OR v_address->>'detail_address' IS NOT NULL
       OR v_address->>'latitude' IS NOT NULL OR v_address->>'longitude' IS NOT NULL
       OR v_address->>'google_place_id' IS NOT NULL
       OR v_address->>'district' IS NOT NULL OR v_address->>'ward' IS NOT NULL
       OR COALESCE(v_address->>'location_verified','false') <> 'false' THEN
      RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
    END IF;
  ELSIF v_address->>'address_source' = 'manual' THEN$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)', $old$    state, locale, customer_note
$old$, $new$    state, locale, customer_note, fulfillment_type
$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)', $old$    NULLIF(btrim(COALESCE(p_payload->>'customer_note', '')), '')
  ) RETURNING * INTO v_request;$old$, $new$    NULLIF(btrim(COALESCE(p_payload->>'customer_note', '')), ''), v_type
  ) RETURNING * INTO v_request;$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)', $old$    v_address->>'address_source' <> 'manual'
$old$, $new$    v_address->>'address_source' IN ('search','map_pin')
$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)', $old$  IF v_address->>'address_source' <> 'manual' THEN$old$, $new$  IF v_address->>'address_source' IN ('search','map_pin') THEN$new$);

REVOKE ALL ON FUNCTION public.direct_order_public_submit_v2(uuid,text,uuid,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_submit_v2(uuid,text,uuid,jsonb) TO service_role;

SELECT pg_temp.direct_pickup_patch('public.direct_order_staff_quote(uuid,uuid,numeric,text)', $old$  SELECT * INTO v_storefront$old$, $new$  IF v_request.fulfillment_type='pickup' AND p_delivery_fee_total <> 0 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_FEE_INVALID';
  END IF;

  SELECT * INTO v_storefront$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_staff_quote(uuid,uuid,numeric,text)', $old$    created_by, expires_at
$old$, $new$    created_by, expires_at, delivery_payment_mode
$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_staff_quote(uuid,uuid,numeric,text)', $old$    now() + make_interval(mins => v_storefront.quote_ttl_minutes)
$old$, $new$    now() + make_interval(mins => v_storefront.quote_ttl_minutes),
    CASE WHEN v_request.fulfillment_type='pickup' THEN 'not_applicable' ELSE 'store_prepaid' END
$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_staff_quote_with_payment_mode(uuid,uuid,numeric,text,text)', $old$  IF p_delivery_payment_mode NOT IN ('customer_direct', 'store_prepaid')$old$, $new$  IF NOT EXISTS (SELECT 1 FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id
    AND ((fulfillment_type='pickup' AND p_delivery_payment_mode='not_applicable' AND p_delivery_fee_total=0)
      OR (fulfillment_type='delivery' AND p_delivery_payment_mode IN ('customer_direct','store_prepaid')))) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_FEE_INVALID';
  END IF;
  IF p_delivery_payment_mode NOT IN ('customer_direct', 'store_prepaid','not_applicable')$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_approve_payment(uuid,uuid,numeric,text)',
 $old$  v_order public.orders%ROWTYPE;$old$,
 $new$  v_order public.orders%ROWTYPE;
  v_previous_direct_pos text := current_setting('app.direct_order_pos_id',true);
  v_previous_direct_request text := current_setting('app.direct_order_request_id',true);$new$);
SELECT pg_temp.direct_pickup_patch('public.direct_order_approve_payment(uuid,uuid,numeric,text)',
 $old$  RETURN jsonb_build_object(
    'request_id', v_request.id,
    'order_id', v_order.id,$old$,
 $new$  PERFORM set_config('app.direct_order_pos_id',COALESCE(v_previous_direct_pos,''),true);
  PERFORM set_config('app.direct_order_request_id',COALESCE(v_previous_direct_request,''),true);
  RETURN jsonb_build_object(
    'request_id', v_request.id,
    'order_id', v_order.id,$new$);

-- Approval labels the exact POS order while its items are inserted, before
-- the financial link exists. Context is transaction-local and order/store scoped.
SELECT pg_temp.direct_pickup_patch('public.direct_order_approve_payment(uuid,uuid,numeric,text)',
 $old$  ) RETURNING * INTO v_order;$old$,
 $new$  ) RETURNING * INTO v_order;
  PERFORM set_config('app.direct_order_pos_id',v_order.id::text,true);
  PERFORM set_config('app.direct_order_request_id',v_request.id::text,true);$new$);

-- Pickup uses the existing dedicated direct-order kitchen board in both
-- print and paperless stores. General dine-in/takeaway KDS routing is unchanged.
CREATE FUNCTION public.direct_order_is_pickup_pos_order(p_order_id uuid,p_store_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 SELECT EXISTS(SELECT 1 FROM public.direct_order_requests r
  JOIN public.direct_order_financials f ON f.request_id=r.id
  WHERE f.order_id=p_order_id AND r.restaurant_id=p_store_id AND r.fulfillment_type='pickup')
 OR (current_setting('app.direct_order_pos_id',true)=p_order_id::text AND EXISTS(
  SELECT 1 FROM public.direct_order_requests r WHERE r.id::text=current_setting('app.direct_order_request_id',true)
   AND r.restaurant_id=p_store_id AND r.fulfillment_type='pickup'));
$$;
REVOKE ALL ON FUNCTION public.direct_order_is_pickup_pos_order(uuid,uuid) FROM PUBLIC,anon,authenticated;
SELECT pg_temp.direct_pickup_patch('public.emergency_sync_order_item()', $old$BEGIN
$old$, $new$BEGIN
  IF public.direct_order_is_pickup_pos_order(NEW.order_id,NEW.restaurant_id) THEN RETURN NEW; END IF;
$new$);
SELECT pg_temp.direct_pickup_patch('public.emergency_sync_combo_component_items()', $old$BEGIN
$old$, $new$BEGIN
  IF public.direct_order_is_pickup_pos_order(NEW.order_id,NEW.restaurant_id) THEN RETURN NEW; END IF;
$new$);
SELECT pg_temp.direct_pickup_patch('public.sync_direct_delivery_ticket_from_kds()', $old$BEGIN
$old$, $new$BEGIN
  IF public.direct_order_is_pickup_pos_order(NEW.order_id,NEW.restaurant_id) THEN RETURN NEW; END IF;
$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_approve_payment(uuid,uuid,numeric,text)', $old$    p_store_id, NULL, 'delivery', 'serving', NULL,$old$, $new$    p_store_id, NULL, CASE WHEN v_request.fulfillment_type='pickup' THEN 'takeaway' ELSE 'delivery' END, 'serving', NULL,$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_approve_payment(uuid,uuid,numeric,text)', $old$    'Direct delivery ' || v_request.reference_code,$old$, $new$    CASE WHEN v_request.fulfillment_type='pickup' THEN 'Direct pickup ' ELSE 'Direct delivery ' END || v_request.reference_code,$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_approve_payment(uuid,uuid,numeric,text)', $old$    delivery_fee_total, final_total, confirmed_bank_reference,
$old$, $new$    delivery_fee_total, final_total, confirmed_bank_reference, delivery_payment_mode,
$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_approve_payment(uuid,uuid,numeric,text)', $old$    NULLIF(btrim(COALESCE(p_confirmed_bank_reference, '')), ''),$old$, $new$    NULLIF(btrim(COALESCE(p_confirmed_bank_reference, '')), ''), v_quote.delivery_payment_mode,$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_staff_list_v2(uuid,text[],integer)', $old$        'reference_code', request_row.reference_code,$old$, $new$        'reference_code', request_row.reference_code,
        'fulfillment_type', request_row.fulfillment_type,$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_delivery_ticket_list(uuid,text[],timestamp with time zone,uuid,integer)', $old$        'request_id', ticket.request_id,$old$, $new$        'request_id', ticket.request_id,
        'fulfillment_type', (SELECT fulfillment_type FROM public.direct_order_requests WHERE id=ticket.request_id),$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_set_dispatch(uuid,uuid,text,numeric)', $old$  SELECT * INTO v_financial$old$, $new$  IF EXISTS (SELECT 1 FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id AND fulfillment_type='pickup') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_DISPATCH_FORBIDDEN';
  END IF;
  SELECT * INTO v_financial$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_order_set_dispatch_with_payment_mode(uuid,uuid,text,numeric)', $old$  SELECT financial.* INTO v_financial$old$, $new$  IF EXISTS (SELECT 1 FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id AND fulfillment_type='pickup') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_DISPATCH_FORBIDDEN';
  END IF;
  SELECT financial.* INTO v_financial$new$);

SELECT pg_temp.direct_pickup_patch('public.direct_delivery_ticket_transition(uuid,uuid,integer,text)', $old$    OR (v_ticket.status = 'ready' AND p_next_status IN ('dispatched', 'cancelled'))$old$, $new$    OR (v_ticket.status = 'ready' AND p_next_status = 'cancelled')
    OR (v_ticket.status = 'ready' AND p_next_status = 'dispatched' AND EXISTS (SELECT 1 FROM public.direct_order_requests WHERE id=v_ticket.request_id AND fulfillment_type='delivery'))
    OR (v_ticket.status = 'ready' AND p_next_status = 'completed' AND EXISTS (SELECT 1 FROM public.direct_order_requests WHERE id=v_ticket.request_id AND fulfillment_type='pickup'))$new$);

CREATE FUNCTION public.direct_order_public_storefront_v2(p_slug text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE payload jsonb; BEGIN
 payload:=public.direct_order_public_storefront(p_slug);
 IF payload IS NULL THEN RETURN NULL; END IF;
 RETURN payload||jsonb_build_object('store_address',(SELECT address FROM public.restaurants WHERE id=(payload->>'store_id')::uuid));
END $$;
CREATE FUNCTION public.direct_order_public_status_v3(p_session_id uuid,p_secret_hash text,p_request_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE payload jsonb; BEGIN
 payload:=public.direct_order_public_status_v2(p_session_id,p_secret_hash,p_request_id);
 RETURN payload||jsonb_build_object('fulfillment_type',(SELECT fulfillment_type FROM public.direct_order_requests WHERE id=p_request_id));
END $$;
CREATE FUNCTION public.direct_order_public_orders_v3(p_session_id uuid,p_secret_hash text,p_limit integer DEFAULT 50) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE payload jsonb; BEGIN
 payload:=public.direct_order_public_orders_v2(p_session_id,p_secret_hash,p_limit);
 RETURN COALESCE((SELECT jsonb_agg(item||jsonb_build_object('fulfillment_type',request.fulfillment_type) ORDER BY ord)
  FROM jsonb_array_elements(payload) WITH ORDINALITY AS rows(item,ord)
  JOIN public.direct_order_requests request ON request.id=(item->>'request_id')::uuid),'[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.direct_order_public_storefront_v2(text),public.direct_order_public_status_v3(uuid,text,uuid),public.direct_order_public_orders_v3(uuid,text,integer) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_storefront_v2(text),public.direct_order_public_status_v3(uuid,text,uuid),public.direct_order_public_orders_v3(uuid,text,integer) TO service_role;

CREATE FUNCTION public.direct_order_cashier_complete_pickup(p_store_id uuid,p_request_id uuid,p_expected_version integer) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth,pg_catalog AS $$
DECLARE ticket public.direct_delivery_fulfillment_tickets%ROWTYPE; result jsonb;
BEGIN
 PERFORM public.direct_order_require_actor(p_store_id,ARRAY['cashier','admin','store_admin','brand_admin','super_admin']);
 PERFORM pg_advisory_xact_lock(hashtextextended('direct-order-complete:'||p_request_id::text,0));
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_requests WHERE id=p_request_id AND restaurant_id=p_store_id AND fulfillment_type='pickup' AND state='approved') THEN
  RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_NOT_APPROVED';
 END IF;
 SELECT * INTO ticket FROM public.direct_delivery_fulfillment_tickets WHERE request_id=p_request_id AND restaurant_id=p_store_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'DIRECT_DELIVERY_TICKET_NOT_FOUND'; END IF;
 IF ticket.status='completed' THEN RETURN to_jsonb(ticket)||jsonb_build_object('idempotent',true); END IF;
 IF ticket.status <> 'ready' THEN RAISE EXCEPTION 'DIRECT_ORDER_PICKUP_NOT_READY'; END IF;
 result:=public.direct_delivery_ticket_transition(p_store_id,ticket.id,p_expected_version,'completed');
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,sender_auth_id,message_type,body)
 VALUES(p_request_id,p_store_id,'cashier',auth.uid(),'system','DIRECT_ORDER_PICKUP_COMPLETED');
 INSERT INTO public.audit_logs(actor_id,action,entity_type,entity_id,details)
 VALUES(auth.uid(),'direct_order_pickup_completed','direct_order_requests',p_request_id,jsonb_build_object('store_id',p_store_id,'ticket_id',ticket.id));
 RETURN result||jsonb_build_object('idempotent',false);
END $$;
REVOKE ALL ON FUNCTION public.direct_order_cashier_complete_pickup(uuid,uuid,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.direct_order_cashier_complete_pickup(uuid,uuid,integer) TO authenticated,service_role;

-- Add durable order/mode labels to existing receipt payloads without new payment paths.
CREATE FUNCTION public.attach_direct_order_fulfillment_receipt() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
DECLARE request public.direct_order_requests%ROWTYPE; mode text;
BEGIN
 SELECT r.* INTO request FROM public.direct_order_financials f
 JOIN public.direct_order_requests r ON r.id=f.request_id WHERE f.order_id=NEW.order_id;
 SELECT delivery_payment_mode INTO mode FROM public.direct_order_financials WHERE order_id=NEW.order_id;
 IF request.id IS NULL AND current_setting('app.direct_order_pos_id',true)=NEW.order_id::text THEN
  SELECT r.* INTO request FROM public.direct_order_requests r
   WHERE r.id::text=current_setting('app.direct_order_request_id',true) AND r.restaurant_id=NEW.restaurant_id;
  SELECT delivery_payment_mode INTO mode FROM public.direct_order_quotes
   WHERE request_id=request.id AND status IN ('active','locked','approved') ORDER BY version DESC LIMIT 1;
 END IF;
 IF request.id IS NOT NULL THEN
  NEW.payload:=NEW.payload||jsonb_build_object('direct_fulfillment_type',request.fulfillment_type,'direct_delivery_payment_mode',mode,'direct_reference_code',request.reference_code);
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.attach_direct_order_fulfillment_receipt() FROM PUBLIC,anon,authenticated;
CREATE TRIGGER zz_direct_order_fulfillment_receipt BEFORE INSERT ON public.print_jobs
 FOR EACH ROW EXECUTE FUNCTION public.attach_direct_order_fulfillment_receipt();
DO $$ BEGIN
 IF to_regprocedure('public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)') IS NULL OR
    to_regprocedure('public.direct_order_cashier_complete_pickup(uuid,uuid,integer)') IS NULL OR
    has_function_privilege('anon','public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)','EXECUTE') OR
    has_function_privilege('authenticated','public.direct_order_public_status_v3(uuid,text,uuid)','EXECUTE') OR
    has_function_privilege('anon','public.direct_order_cashier_complete_pickup(uuid,uuid,integer)','EXECUTE') OR
    NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.direct_order_quotes'::regclass AND conname='direct_order_pickup_quote_zero_fee') OR
    NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.direct_order_requests'::regclass AND tgname='direct_order_fulfillment_type_immutable') THEN
  RAISE EXCEPTION 'DIRECT_PICKUP_MIGRATION_VERIFICATION_FAILED';
 END IF;
END $$;
COMMIT;
