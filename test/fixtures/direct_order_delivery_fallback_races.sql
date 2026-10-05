CREATE SCHEMA fallback_test;
CREATE TABLE fallback_test.races(operation text PRIMARY KEY, fixture jsonb NOT NULL);
CREATE FUNCTION fallback_test.approved_ready(p_prepaid boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE f jsonb; result jsonb; t uuid;
BEGIN
 f:=photo_test.create_request(true,CASE WHEN p_prepaid THEN 'store_prepaid' ELSE 'customer_direct' END);
 IF p_prepaid THEN UPDATE public.direct_order_quotes SET delivery_fee_pretax=20000,delivery_fee_vat=1600,delivery_fee_total=21600,final_total=129600 WHERE id=(f->>'quote_id')::uuid; END IF;
 result:=public.direct_order_approve_photo_payment((f->>'store_id')::uuid,(f->>'request_id')::uuid,CASE WHEN p_prepaid THEN 129600 ELSE 108000 END,(f->>'quote_id')::uuid,(f->>'proof_id')::uuid);
 t:=(result->>'ticket_id')::uuid;
 PERFORM public.direct_delivery_ticket_transition((f->>'store_id')::uuid,t,1,'preparing');
 PERFORM public.direct_delivery_ticket_transition((f->>'store_id')::uuid,t,2,'ready');
 RETURN f;
END $$;
DO $$
DECLARE f jsonb; c jsonb;
BEGIN
 f:=fallback_test.approved_ready(true);
 c:=public.direct_order_staff_offer_pickup((f->>'store_id')::uuid,(f->>'request_id')::uuid,1,'No driver');
 f:=f||jsonb_build_object('offer_id',c->'pickup_offer'->'id');
 INSERT INTO fallback_test.races VALUES('consent',f),('refund',f);
 INSERT INTO fallback_test.races VALUES('dispatch',fallback_test.approved_ready()),('offer_dispatch',fallback_test.approved_ready());
END $$;
CREATE FUNCTION fallback_test.race_call(p_operation text,p_first boolean DEFAULT true) RETURNS void LANGUAGE plpgsql AS $$
DECLARE f jsonb; sid uuid; secret text; result jsonb;
BEGIN
 SELECT fixture INTO STRICT f FROM fallback_test.races WHERE operation=p_operation;
 IF p_operation='consent' THEN
  SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=(f->>'request_id')::uuid;
  SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
  result:=public.direct_order_public_decide_pickup(sid,secret,(f->>'request_id')::uuid,(f->>'offer_id')::uuid,true,true);
 ELSIF p_operation='refund' THEN
  result:=public.direct_order_staff_record_pickup_refund((f->>'store_id')::uuid,(f->>'request_id')::uuid,(f->>'offer_id')::uuid,'race-bank-reference');
 ELSIF p_operation='dispatch' THEN
  result:=public.direct_order_set_dispatch_v3((f->>'store_id')::uuid,(f->>'request_id')::uuid,3,'be','https://be.example/race');
 ELSE
  BEGIN
   IF p_first THEN result:=public.direct_order_staff_offer_pickup((f->>'store_id')::uuid,(f->>'request_id')::uuid,1,'Race no driver');
   ELSE result:=public.direct_order_set_dispatch_v3((f->>'store_id')::uuid,(f->>'request_id')::uuid,3,'be','https://be.example/race'); END IF;
  EXCEPTION WHEN OTHERS THEN
   IF SQLERRM NOT IN ('DIRECT_ORDER_PICKUP_NOT_ALLOWED','DIRECT_ORDER_PICKUP_OFFER_PENDING') THEN RAISE; END IF;
  END;
 END IF;
END $$;
