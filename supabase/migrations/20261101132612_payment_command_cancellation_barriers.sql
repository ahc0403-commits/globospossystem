-- production-gate: self-verifying
-- A durable cancellation barrier prevents a late, uncertain payment request
-- from charging after the cashier explicitly starts a different intent.
-- Native pricing/payment/stock/invoice functions retain their definitions.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

CREATE TABLE pos_command_private.payment_cancellations (
  actor_auth_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  actor_profile_id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  order_id uuid NOT NULL,
  cancelled_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(actor_auth_id,operation_id)
);
ALTER TABLE pos_command_private.payment_cancellations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON pos_command_private.payment_cancellations FROM PUBLIC,anon,authenticated,service_role;
ALTER TABLE pos_command_private.payment_receipts
  ADD COLUMN expected_payment_count integer,
  ADD COLUMN require_full_payment boolean;

CREATE OR REPLACE FUNCTION public.process_payment_once_v1(
  p_operation_id uuid,p_order_id uuid,p_store_id uuid,p_amount numeric,p_method text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='5s' AS $$
DECLARE actor_id uuid; fingerprint bytea; prior pos_command_private.payment_receipts%ROWTYPE;
  payment public.payments%ROWTYPE; result jsonb; cancelled pos_command_private.payment_cancellations%ROWTYPE;
BEGIN
  actor_id:=pos_command_private.require_payment_actor(p_store_id);
  IF p_operation_id IS NULL OR p_order_id IS NULL OR p_amount IS NULL OR p_method IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_OPERATION_INPUT_INVALID' USING ERRCODE='22023'; END IF;
  -- trim_scale makes numerically equal JSON amounts (8000 / 8000.00) identical.
  -- No PIN, credential, entire request body or mutable authorization is stored.
  fingerprint:=pg_catalog.sha256(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
    'kind','single_payment','order_id',p_order_id,'store_id',p_store_id,
    'amount',pg_catalog.trim_scale(p_amount),'method',p_method)::text,'UTF8'));
  -- Serialize only this actor's original command. The native payment routine
  -- retains its order/stock locks. An exception rolls back both payment/receipt.
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    auth.uid()::text||':'||p_operation_id::text,0));
  SELECT * INTO prior FROM pos_command_private.payment_receipts r
    WHERE r.actor_auth_id=auth.uid() AND r.operation_id=p_operation_id;
  IF FOUND THEN
    IF prior.actor_profile_id<>actor_id OR prior.restaurant_id<>p_store_id THEN
      RAISE EXCEPTION 'PAYMENT_FORBIDDEN' USING ERRCODE='42501'; END IF;
    IF prior.request_hash<>fingerprint THEN
      RAISE EXCEPTION 'PAYMENT_OPERATION_CONFLICT' USING ERRCODE='22023'; END IF;
    RETURN prior.result;
  END IF;
  SELECT * INTO cancelled FROM pos_command_private.payment_cancellations c
    WHERE c.actor_auth_id=auth.uid() AND c.operation_id=p_operation_id;
  IF FOUND THEN
    IF cancelled.actor_profile_id<>actor_id OR cancelled.restaurant_id<>p_store_id THEN
      RAISE EXCEPTION 'PAYMENT_FORBIDDEN' USING ERRCODE='42501'; END IF;
    IF cancelled.order_id<>p_order_id THEN
      RAISE EXCEPTION 'PAYMENT_OPERATION_CONFLICT' USING ERRCODE='22023'; END IF;
    RAISE EXCEPTION 'PAYMENT_OPERATION_CANCELLED' USING ERRCODE='P0001';
  END IF;
  payment:=public.process_payment(p_order_id,p_store_id,p_amount,p_method);
  IF payment.id IS NULL OR payment.order_id<>p_order_id OR payment.restaurant_id<>p_store_id THEN
    RAISE EXCEPTION 'PAYMENT_OPERATION_RESULT_INVALID'; END IF;
  result:=pg_catalog.to_jsonb(payment);
  INSERT INTO pos_command_private.payment_receipts(actor_auth_id,operation_id,actor_profile_id,
    restaurant_id,order_id,request_hash,payment_id,result)
    VALUES(auth.uid(),p_operation_id,actor_id,p_store_id,p_order_id,fingerprint,payment.id,result);
  RETURN result;
END $$;

CREATE FUNCTION public.process_single_payment_command_v2(
  p_operation_id uuid,p_order_id uuid,p_store_id uuid,p_amount numeric,p_method text,
  p_expected_payment_count integer,p_require_full_payment boolean
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='5s' AS $$
DECLARE actor_id uuid; fingerprint bytea; prior pos_command_private.payment_receipts%ROWTYPE;
  cancelled pos_command_private.payment_cancellations%ROWTYPE;
  payment public.payments%ROWTYPE; result jsonb; existing_count bigint; final_status text;
BEGIN
  actor_id:=pos_command_private.require_payment_actor(p_store_id);
  IF p_operation_id IS NULL OR p_order_id IS NULL OR p_amount IS NULL OR p_method IS NULL
    OR p_expected_payment_count IS NULL OR p_expected_payment_count<0 OR p_require_full_payment IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_OPERATION_INPUT_INVALID' USING ERRCODE='22023'; END IF;
  fingerprint:=pg_catalog.sha256(pg_catalog.convert_to(pg_catalog.jsonb_build_object(
    'kind','single_payment_v2','order_id',p_order_id,'store_id',p_store_id,
    'amount',pg_catalog.trim_scale(p_amount),'method',p_method,
    'expected_payment_count',p_expected_payment_count,'require_full_payment',p_require_full_payment)::text,'UTF8'));
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    auth.uid()::text||':'||p_operation_id::text,0));
  SELECT * INTO prior FROM pos_command_private.payment_receipts r
    WHERE r.actor_auth_id=auth.uid() AND r.operation_id=p_operation_id;
  IF FOUND THEN
    IF prior.actor_profile_id<>actor_id OR prior.restaurant_id<>p_store_id THEN
      RAISE EXCEPTION 'PAYMENT_FORBIDDEN' USING ERRCODE='42501'; END IF;
    IF prior.request_hash<>fingerprint THEN
      RAISE EXCEPTION 'PAYMENT_OPERATION_CONFLICT' USING ERRCODE='22023'; END IF;
    RETURN prior.result;
  END IF;
  SELECT * INTO cancelled FROM pos_command_private.payment_cancellations c
    WHERE c.actor_auth_id=auth.uid() AND c.operation_id=p_operation_id;
  IF FOUND THEN
    IF cancelled.actor_profile_id<>actor_id OR cancelled.restaurant_id<>p_store_id THEN
      RAISE EXCEPTION 'PAYMENT_FORBIDDEN' USING ERRCODE='42501'; END IF;
    IF cancelled.order_id<>p_order_id THEN
      RAISE EXCEPTION 'PAYMENT_OPERATION_CONFLICT' USING ERRCODE='22023'; END IF;
    RAISE EXCEPTION 'PAYMENT_OPERATION_CANCELLED' USING ERRCODE='P0001';
  END IF;
  -- The same order lock used by native payment serializes distinct cashier
  -- intents. Count only this order's immutable payment ledger once per command,
  -- never on a screen refresh or once per menu item.
  PERFORM 1 FROM public.orders o WHERE o.id=p_order_id AND o.restaurant_id=p_store_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  SELECT count(*) INTO existing_count FROM public.payments p
    WHERE p.order_id=p_order_id AND p.restaurant_id=p_store_id;
  IF existing_count<>p_expected_payment_count THEN
    RAISE EXCEPTION 'PAYMENT_ORDER_CHANGED'; END IF;
  payment:=public.process_payment(p_order_id,p_store_id,p_amount,p_method);
  IF payment.id IS NULL OR payment.order_id<>p_order_id OR payment.restaurant_id<>p_store_id THEN
    RAISE EXCEPTION 'PAYMENT_OPERATION_RESULT_INVALID'; END IF;
  IF p_require_full_payment THEN
    SELECT o.status::text INTO final_status FROM public.orders o WHERE o.id=p_order_id;
    IF final_status IS DISTINCT FROM 'completed' THEN
      -- A stale full-payment quote must not silently become a partial payment.
      -- Raising here rolls back the native payment, stock, job and audit writes.
      RAISE EXCEPTION 'PAYMENT_ORDER_CHANGED'; END IF;
  END IF;
  result:=pg_catalog.to_jsonb(payment);
  INSERT INTO pos_command_private.payment_receipts(actor_auth_id,operation_id,actor_profile_id,
    restaurant_id,order_id,request_hash,payment_id,result,expected_payment_count,require_full_payment)
    VALUES(auth.uid(),p_operation_id,actor_id,p_store_id,p_order_id,fingerprint,payment.id,result,
      p_expected_payment_count,p_require_full_payment);
  RETURN result;
END $$;

CREATE FUNCTION public.cancel_single_payment_command_v1(p_operation_id uuid,p_order_id uuid,p_store_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='5s' AS $$
DECLARE actor_id uuid; prior pos_command_private.payment_receipts%ROWTYPE;
  cancelled pos_command_private.payment_cancellations%ROWTYPE;
BEGIN
  actor_id:=pos_command_private.require_payment_actor(p_store_id);
  IF p_operation_id IS NULL OR p_order_id IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_OPERATION_INPUT_INVALID' USING ERRCODE='22023'; END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    auth.uid()::text||':'||p_operation_id::text,0));
  SELECT * INTO prior FROM pos_command_private.payment_receipts r
    WHERE r.actor_auth_id=auth.uid() AND r.operation_id=p_operation_id;
  IF FOUND THEN
    IF prior.actor_profile_id<>actor_id OR prior.restaurant_id<>p_store_id THEN
      RAISE EXCEPTION 'PAYMENT_FORBIDDEN' USING ERRCODE='42501'; END IF;
    IF prior.order_id<>p_order_id THEN
      RAISE EXCEPTION 'PAYMENT_OPERATION_CONFLICT' USING ERRCODE='22023'; END IF;
    RETURN jsonb_build_object('status','confirmed','operation_id',p_operation_id,
      'order_id',p_order_id,'store_id',p_store_id,'result',prior.result);
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.orders o WHERE o.id=p_order_id AND o.restaurant_id=p_store_id) THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  INSERT INTO pos_command_private.payment_cancellations(actor_auth_id,operation_id,actor_profile_id,restaurant_id,order_id)
    VALUES(auth.uid(),p_operation_id,actor_id,p_store_id,p_order_id) ON CONFLICT DO NOTHING;
  SELECT * INTO STRICT cancelled FROM pos_command_private.payment_cancellations c
    WHERE c.actor_auth_id=auth.uid() AND c.operation_id=p_operation_id;
  IF cancelled.actor_profile_id<>actor_id OR cancelled.restaurant_id<>p_store_id THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN' USING ERRCODE='42501'; END IF;
  IF cancelled.order_id<>p_order_id THEN
    RAISE EXCEPTION 'PAYMENT_OPERATION_CONFLICT' USING ERRCODE='22023'; END IF;
  RETURN jsonb_build_object('status','cancelled','operation_id',p_operation_id,
    'order_id',p_order_id,'store_id',p_store_id,'cancelled_at',cancelled.cancelled_at);
END $$;
REVOKE ALL ON FUNCTION public.process_single_payment_command_v2(uuid,uuid,uuid,numeric,text,integer,boolean)
  FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.cancel_single_payment_command_v1(uuid,uuid,uuid)
  FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.process_single_payment_command_v2(uuid,uuid,uuid,numeric,text,integer,boolean)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_single_payment_command_v1(uuid,uuid,uuid) TO authenticated;
DO $$ BEGIN
  IF has_table_privilege('authenticated','pos_command_private.payment_cancellations','SELECT')
    OR has_table_privilege('service_role','pos_command_private.payment_cancellations','INSERT')
    OR has_function_privilege('anon','public.process_single_payment_command_v2(uuid,uuid,uuid,numeric,text,integer,boolean)','EXECUTE')
    OR has_function_privilege('service_role','public.cancel_single_payment_command_v1(uuid,uuid,uuid)','EXECUTE')
    OR NOT has_function_privilege('authenticated','public.cancel_single_payment_command_v1(uuid,uuid,uuid)','EXECUTE')
    THEN RAISE EXCEPTION 'PAYMENT_CANCELLATION_BARRIER_ACL_INVALID'; END IF;
END $$;
COMMIT;
