-- production-gate: self-verifying
-- Additive single-payment recovery contract. Existing financial entrypoints,
-- promotion/stock/tax rules and old web clients keep their current behavior.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

CREATE SCHEMA pos_command_private;
REVOKE ALL ON SCHEMA pos_command_private FROM PUBLIC,anon,authenticated,service_role;
CREATE TABLE pos_command_private.payment_receipts (
  actor_auth_id uuid NOT NULL,
  operation_id uuid NOT NULL,
  actor_profile_id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  order_id uuid NOT NULL,
  request_hash bytea NOT NULL CHECK(octet_length(request_hash)=32),
  payment_id uuid NOT NULL,
  result jsonb NOT NULL CHECK(jsonb_typeof(result)='object'),
  confirmed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(actor_auth_id,operation_id),
  UNIQUE(payment_id)
);
ALTER TABLE pos_command_private.payment_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON pos_command_private.payment_receipts FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION pos_command_private.require_payment_actor(p_store_id uuid)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE actor_id uuid; actor_count integer;
BEGIN
  IF auth.uid() IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN' USING ERRCODE='42501'; END IF;
  SELECT min(u.id::text)::uuid,count(*) INTO actor_id,actor_count FROM public.users u
    WHERE u.auth_id=auth.uid() AND u.is_active
      AND u.role IN('cashier','admin','store_admin','brand_admin','super_admin');
  IF actor_count<>1 OR NOT(coalesce(public.is_super_admin(),false) OR EXISTS(
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) AS s(store_id) WHERE s.store_id=p_store_id)) THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN' USING ERRCODE='42501'; END IF;
  RETURN actor_id;
END $$;
REVOKE ALL ON FUNCTION pos_command_private.require_payment_actor(uuid)
  FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.process_payment_once_v1(
  p_operation_id uuid,p_order_id uuid,p_store_id uuid,p_amount numeric,p_method text
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='5s' AS $$
DECLARE actor_id uuid; fingerprint bytea; prior pos_command_private.payment_receipts%ROWTYPE;
  payment public.payments%ROWTYPE; result jsonb;
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
  payment:=public.process_payment(p_order_id,p_store_id,p_amount,p_method);
  IF payment.id IS NULL OR payment.order_id<>p_order_id OR payment.restaurant_id<>p_store_id THEN
    RAISE EXCEPTION 'PAYMENT_OPERATION_RESULT_INVALID'; END IF;
  result:=pg_catalog.to_jsonb(payment);
  INSERT INTO pos_command_private.payment_receipts(actor_auth_id,operation_id,actor_profile_id,
    restaurant_id,order_id,request_hash,payment_id,result)
    VALUES(auth.uid(),p_operation_id,actor_id,p_store_id,p_order_id,fingerprint,payment.id,result);
  RETURN result;
END $$;

CREATE FUNCTION public.get_payment_command_receipts_v1(p_store_id uuid,p_operation_ids uuid[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE actor_id uuid; result jsonb;
BEGIN
  actor_id:=pos_command_private.require_payment_actor(p_store_id);
  IF p_operation_ids IS NULL OR cardinality(p_operation_ids)>100
    OR coalesce(array_ndims(p_operation_ids),1)<>1 OR array_position(p_operation_ids,NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'PAYMENT_RECEIPT_BATCH_INVALID' USING ERRCODE='22023'; END IF;
  WITH requested AS MATERIALIZED(SELECT DISTINCT unnest(p_operation_ids) operation_id)
  SELECT coalesce(jsonb_agg(jsonb_build_object('operation_id',r.operation_id,'order_id',r.order_id,
      'store_id',r.restaurant_id,'payment_id',r.payment_id,'confirmed_at',r.confirmed_at,
      'result',r.result) ORDER BY r.operation_id),'[]'::jsonb) INTO result
    FROM requested q JOIN pos_command_private.payment_receipts r
      ON r.actor_auth_id=auth.uid() AND r.operation_id=q.operation_id
    WHERE r.actor_profile_id=actor_id AND r.restaurant_id=p_store_id;
  RETURN result;
END $$;

REVOKE ALL ON FUNCTION public.process_payment_once_v1(uuid,uuid,uuid,numeric,text)
  FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.get_payment_command_receipts_v1(uuid,uuid[])
  FROM PUBLIC,anon,authenticated,service_role;
GRANT EXECUTE ON FUNCTION public.process_payment_once_v1(uuid,uuid,uuid,numeric,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_payment_command_receipts_v1(uuid,uuid[]) TO authenticated;
DO $$ BEGIN
  IF has_schema_privilege('authenticated','pos_command_private','USAGE')
    OR has_table_privilege('authenticated','pos_command_private.payment_receipts','SELECT')
    OR has_function_privilege('anon','public.process_payment_once_v1(uuid,uuid,uuid,numeric,text)','EXECUTE')
    OR has_function_privilege('service_role','public.get_payment_command_receipts_v1(uuid,uuid[])','EXECUTE')
    OR NOT has_function_privilege('authenticated','public.process_payment_once_v1(uuid,uuid,uuid,numeric,text)','EXECUTE')
    OR NOT has_function_privilege('authenticated','public.get_payment_command_receipts_v1(uuid,uuid[])','EXECUTE')
    OR NOT(SELECT prosecdef AND proconfig @> ARRAY['search_path=""'] FROM pg_proc
      WHERE oid='public.process_payment_once_v1(uuid,uuid,uuid,numeric,text)'::regprocedure)
    THEN RAISE EXCEPTION 'PAYMENT_COMMAND_RECEIPT_ACL_INVALID'; END IF;
END $$;
COMMIT;
