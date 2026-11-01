-- production-gate: self-verifying
-- Make the mandatory day-aware API recoverable even without the optional
-- historical create_order_with_client_mutation_id rollout. Financial, menu,
-- discount, inventory, print and fulfillment work remains in native create_order.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

CREATE TABLE pos_command_private.order_create_receipts (
  actor_auth_id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  client_mutation_id text NOT NULL CHECK(length(client_mutation_id) BETWEEN 1 AND 160),
  actor_profile_id uuid NOT NULL,
  table_id uuid NOT NULL,
  business_date date NOT NULL,
  request_hash bytea NOT NULL CHECK(octet_length(request_hash)=32),
  order_id uuid NOT NULL,
  confirmed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(actor_auth_id,restaurant_id,client_mutation_id),
  UNIQUE(order_id)
);
ALTER TABLE pos_command_private.order_create_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON pos_command_private.order_create_receipts FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION pos_command_private.require_order_create_actor(p_store_id uuid)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE actor_id uuid; actor_count integer;
BEGIN
  IF auth.uid() IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN' USING ERRCODE='42501'; END IF;
  SELECT min(u.id::text)::uuid,count(*) INTO actor_id,actor_count
    FROM public.users u WHERE u.auth_id=auth.uid() AND u.is_active
      AND u.role IN('waiter','admin','store_admin','super_admin');
  IF actor_count<>1 OR NOT(coalesce(public.is_super_admin(),false) OR EXISTS(
    SELECT 1 FROM public.user_accessible_stores(auth.uid()) AS s(store_id) WHERE s.store_id=p_store_id)) THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN' USING ERRCODE='42501'; END IF;
  RETURN actor_id;
END $$;
REVOKE ALL ON FUNCTION pos_command_private.require_order_create_actor(uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.create_order_for_business_day(p_store_id uuid,p_table_id uuid,p_items jsonb,
  p_client_mutation_id text,p_business_date date) RETURNS public.orders
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='5s' AS $$
DECLARE actor_id uuid; command_id text; fingerprint bytea;
  prior pos_command_private.order_create_receipts%ROWTYPE; result public.orders%ROWTYPE;
BEGIN
  actor_id:=pos_command_private.require_order_create_actor(p_store_id);
  command_id:=nullif(btrim(coalesce(p_client_mutation_id,'')),'');
  IF command_id IS NULL OR length(command_id)>160 THEN
    RAISE EXCEPTION 'CLIENT_MUTATION_ID_REQUIRED' USING ERRCODE='22023'; END IF;
  IF p_table_id IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
    OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 500 OR octet_length(p_items::text)>1048576 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED' USING ERRCODE='22023'; END IF;
  PERFORM public.ensure_store_operational_day(p_store_id);
  IF EXISTS(SELECT 1 FROM public.table_operational_reset_policies WHERE restaurant_id=p_store_id AND is_enabled)
    AND p_business_date IS DISTINCT FROM (clock_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date THEN
    RAISE EXCEPTION 'ORDER_BUSINESS_DAY_EXPIRED'; END IF;
  fingerprint:=sha256(convert_to(jsonb_build_object('table_id',p_table_id,'items',p_items,
    'business_date',p_business_date)::text,'UTF8'));
  PERFORM pg_advisory_xact_lock(hashtextextended('order-create-command:'||p_store_id||':'||auth.uid()||':'||command_id,0));
  SELECT * INTO prior FROM pos_command_private.order_create_receipts
    WHERE actor_auth_id=auth.uid() AND restaurant_id=p_store_id AND client_mutation_id=command_id;
  IF FOUND THEN
    IF prior.request_hash<>fingerprint THEN
      RAISE EXCEPTION 'ORDER_CREATE_OPERATION_CONFLICT' USING ERRCODE='22023'; END IF;
    SELECT * INTO result FROM public.orders WHERE id=prior.order_id AND restaurant_id=p_store_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_CREATE_RESULT_UNAVAILABLE'; END IF;
  ELSE
    IF to_regprocedure('public.create_order_with_client_mutation_id(uuid,uuid,jsonb,text)') IS NOT NULL THEN
      result:=public.create_order_with_client_mutation_id(p_store_id,p_table_id,p_items,command_id);
    ELSE
      result:=public.create_order(p_store_id,p_table_id,p_items);
    END IF;
    IF result.id IS NULL OR result.restaurant_id IS DISTINCT FROM p_store_id OR result.table_id IS DISTINCT FROM p_table_id THEN
      RAISE EXCEPTION 'ORDER_CREATE_OPERATION_CONFLICT' USING ERRCODE='22023'; END IF;
    INSERT INTO pos_command_private.order_create_receipts(actor_auth_id,restaurant_id,client_mutation_id,
      actor_profile_id,table_id,business_date,request_hash,order_id)
    VALUES(auth.uid(),p_store_id,command_id,actor_id,p_table_id,
      coalesce(p_business_date,(clock_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date),fingerprint,result.id);
  END IF;
  IF NOT public.table_order_is_current(result) THEN RAISE EXCEPTION 'ORDER_BUSINESS_DAY_EXPIRED'; END IF;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.create_order_for_business_day(uuid,uuid,jsonb,text,date) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.create_order_for_business_day(uuid,uuid,jsonb,text,date) TO authenticated,service_role;

-- CREATE OR REPLACE preserves the native function owner. A trusted migration
-- role may differ from that owner; give only this private contract's rights to
-- the actual existing definer, never to an application/JWT role.
DO $definer$ DECLARE owner_name text;
BEGIN
  SELECT pg_get_userbyid(proowner) INTO owner_name FROM pg_proc
    WHERE oid='public.create_order_for_business_day(uuid,uuid,jsonb,text,date)'::regprocedure;
  IF owner_name NOT IN ('postgres','supabase_admin') THEN
    RAISE EXCEPTION 'ORDER_CREATE_UNREVIEWED_DEFINER'; END IF;
  EXECUTE format('GRANT USAGE ON SCHEMA pos_command_private TO %I',owner_name);
  EXECUTE format('GRANT SELECT,INSERT ON pos_command_private.order_create_receipts TO %I',owner_name);
  EXECUTE format('GRANT EXECUTE ON FUNCTION pos_command_private.require_order_create_actor(uuid) TO %I',owner_name);
END $definer$;

CREATE FUNCTION public.get_order_create_receipts_v1(p_store_id uuid,p_client_mutation_ids text[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM pos_command_private.require_order_create_actor(p_store_id);
  IF p_client_mutation_ids IS NULL OR cardinality(p_client_mutation_ids)>100
    OR coalesce(array_ndims(p_client_mutation_ids),1)<>1 OR array_position(p_client_mutation_ids,NULL) IS NOT NULL
    OR EXISTS(SELECT 1 FROM unnest(p_client_mutation_ids) id WHERE length(btrim(id)) NOT BETWEEN 1 AND 160) THEN
    RAISE EXCEPTION 'ORDER_CREATE_RECEIPT_BATCH_INVALID' USING ERRCODE='22023'; END IF;
  WITH requested AS MATERIALIZED(SELECT DISTINCT unnest(p_client_mutation_ids) command_id)
  SELECT coalesce(jsonb_agg(jsonb_build_object('client_mutation_id',r.client_mutation_id,
    'store_id',r.restaurant_id,'order_id',r.order_id,'table_id',r.table_id,'business_date',r.business_date,
    'confirmed_at',r.confirmed_at) ORDER BY r.client_mutation_id),'[]'::jsonb) INTO result
    FROM requested q JOIN pos_command_private.order_create_receipts r ON r.client_mutation_id=q.command_id
    WHERE r.actor_auth_id=auth.uid() AND r.restaurant_id=p_store_id;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.get_order_create_receipts_v1(uuid,text[]) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_order_create_receipts_v1(uuid,text[]) TO authenticated;

DO $$ BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='pos_command_private' AND c.relname='order_create_receipts' AND c.relrowsecurity)
    OR has_table_privilege('authenticated','pos_command_private.order_create_receipts','SELECT')
    OR has_function_privilege('anon','public.create_order_for_business_day(uuid,uuid,jsonb,text,date)','EXECUTE')
    OR has_function_privilege('anon','public.get_order_create_receipts_v1(uuid,text[])','EXECUTE') THEN
    RAISE EXCEPTION 'ORDER_CREATE_RECEIPT_ACL_INVALID'; END IF;
END $$;
COMMIT;
