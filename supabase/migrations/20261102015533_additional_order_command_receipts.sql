-- production-gate: self-verifying
-- One native add-items batch and one immutable command receipt in the same
-- transaction. Never replay through an unkeyed compatibility function.
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';

CREATE TABLE pos_command_private.order_add_receipts (
  actor_auth_id uuid NOT NULL,
  restaurant_id uuid NOT NULL,
  client_mutation_id text NOT NULL CHECK(length(client_mutation_id) BETWEEN 1 AND 160),
  actor_profile_id uuid NOT NULL,
  order_id uuid NOT NULL,
  request_hash bytea NOT NULL CHECK(octet_length(request_hash)=32),
  item_ids uuid[] NOT NULL CHECK(cardinality(item_ids) BETWEEN 1 AND 500),
  confirmed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY(actor_auth_id,restaurant_id,client_mutation_id)
);
ALTER TABLE pos_command_private.order_add_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON pos_command_private.order_add_receipts FROM PUBLIC,anon,authenticated,service_role;

CREATE FUNCTION public.add_order_items_once_v1(p_order_id uuid,p_store_id uuid,p_items jsonb,p_client_mutation_id text)
RETURNS SETOF public.order_items LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='5s' AS $$
DECLARE actor_id uuid; command_id text; fingerprint bytea; ids uuid[];
  prior pos_command_private.order_add_receipts%ROWTYPE;
BEGIN
  actor_id:=pos_command_private.require_order_create_actor(p_store_id);
  command_id:=nullif(btrim(coalesce(p_client_mutation_id,'')),'');
  IF command_id IS NULL OR length(command_id)>160 THEN
    RAISE EXCEPTION 'CLIENT_MUTATION_ID_REQUIRED' USING ERRCODE='22023'; END IF;
  IF p_order_id IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
    OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 500 OR octet_length(p_items::text)>1048576 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED' USING ERRCODE='22023'; END IF;
  fingerprint:=sha256(convert_to(jsonb_build_object('order_id',p_order_id,'items',p_items)::text,'UTF8'));
  PERFORM pg_advisory_xact_lock(hashtextextended('order-add-command:'||p_store_id||':'||auth.uid()||':'||command_id,0));
  SELECT * INTO prior FROM pos_command_private.order_add_receipts
    WHERE actor_auth_id=auth.uid() AND restaurant_id=p_store_id AND client_mutation_id=command_id;
  IF FOUND THEN
    IF prior.request_hash<>fingerprint THEN
      RAISE EXCEPTION 'ORDER_ADD_OPERATION_CONFLICT' USING ERRCODE='22023'; END IF;
    ids:=prior.item_ids;
  ELSE
    PERFORM public.ensure_store_operational_day(p_store_id);
    IF NOT EXISTS(SELECT 1 FROM public.orders o WHERE o.id=p_order_id
      AND o.restaurant_id=p_store_id AND public.table_order_is_current(o)) THEN
      RAISE EXCEPTION 'ORDER_BUSINESS_DAY_EXPIRED'; END IF;
    -- The native function preserves option validation, non-revenue barriers,
    -- discounts, inventory, takeout snapshots and print/fulfillment events.
    SELECT array_agg(i.id) INTO ids FROM public.add_items_to_order(p_order_id,p_store_id,p_items) i;
    IF cardinality(ids) IS DISTINCT FROM jsonb_array_length(p_items) THEN
      RAISE EXCEPTION 'ORDER_ADD_OPERATION_CONFLICT'; END IF;
    INSERT INTO pos_command_private.order_add_receipts(actor_auth_id,restaurant_id,client_mutation_id,
      actor_profile_id,order_id,request_hash,item_ids)
      VALUES(auth.uid(),p_store_id,command_id,actor_id,p_order_id,fingerprint,ids);
  END IF;
  RETURN QUERY SELECT i.* FROM unnest(ids) WITH ORDINALITY requested(id,ord)
    JOIN public.order_items i ON i.id=requested.id AND i.restaurant_id=p_store_id AND i.order_id=p_order_id
    ORDER BY requested.ord;
END $$;
REVOKE ALL ON FUNCTION public.add_order_items_once_v1(uuid,uuid,jsonb,text) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.add_order_items_once_v1(uuid,uuid,jsonb,text) TO authenticated;

CREATE FUNCTION public.get_order_add_receipts_v1(p_store_id uuid,p_client_mutation_ids text[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' AS $$
DECLARE result jsonb;
BEGIN
  PERFORM pos_command_private.require_order_create_actor(p_store_id);
  IF p_client_mutation_ids IS NULL OR cardinality(p_client_mutation_ids)>100
    OR coalesce(array_ndims(p_client_mutation_ids),1)<>1 OR array_position(p_client_mutation_ids,NULL) IS NOT NULL
    OR EXISTS(SELECT 1 FROM unnest(p_client_mutation_ids) id WHERE length(btrim(id)) NOT BETWEEN 1 AND 160) THEN
    RAISE EXCEPTION 'ORDER_ADD_RECEIPT_BATCH_INVALID' USING ERRCODE='22023'; END IF;
  WITH requested AS MATERIALIZED(SELECT DISTINCT unnest(p_client_mutation_ids) command_id)
  SELECT coalesce(jsonb_agg(jsonb_build_object('client_mutation_id',r.client_mutation_id,
    'store_id',r.restaurant_id,'order_id',r.order_id,'item_ids',r.item_ids,'confirmed_at',r.confirmed_at)
    ORDER BY r.client_mutation_id),'[]'::jsonb) INTO result FROM requested q
    JOIN pos_command_private.order_add_receipts r ON r.client_mutation_id=q.command_id
    WHERE r.actor_auth_id=auth.uid() AND r.restaurant_id=p_store_id;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.get_order_add_receipts_v1(uuid,text[]) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.get_order_add_receipts_v1(uuid,text[]) TO authenticated;

-- Multiple independent original commands use one bounded transport batch.
-- Each native financial/order operation retains its own atomic subtransaction;
-- a rejected order does not erase earlier successful commands or their receipts.
CREATE FUNCTION public.execute_order_command_batch_v1(p_store_id uuid,p_commands jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' SET lock_timeout='5s' AS $$
DECLARE command jsonb; result jsonb:='[]'::jsonb; order_row public.orders%ROWTYPE;
  code text; message text; total_lines integer;
BEGIN
  PERFORM pos_command_private.require_order_create_actor(p_store_id);
  IF jsonb_typeof(p_commands) IS DISTINCT FROM 'array' OR jsonb_array_length(p_commands) NOT BETWEEN 1 AND 20
    OR octet_length(p_commands::text)>1048576 THEN
    RAISE EXCEPTION 'ORDER_COMMAND_BATCH_INVALID' USING ERRCODE='22023'; END IF;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_commands) c WHERE
    coalesce(c->>'kind','') NOT IN ('create','add')
    OR length(coalesce(c->>'operation','')) NOT BETWEEN 1 AND 160
    OR (c->'params'->>'p_store_id') IS DISTINCT FROM p_store_id::text
    OR jsonb_typeof(c->'params'->'p_items') IS DISTINCT FROM 'array') THEN
    RAISE EXCEPTION 'ORDER_COMMAND_BATCH_INVALID' USING ERRCODE='22023'; END IF;
  SELECT sum(jsonb_array_length(c->'params'->'p_items')) INTO total_lines FROM jsonb_array_elements(p_commands) c;
  IF total_lines>500 OR EXISTS(SELECT 1 FROM jsonb_array_elements(p_commands) c
    WHERE jsonb_array_length(c->'params'->'p_items')=0) THEN
    RAISE EXCEPTION 'ORDER_COMMAND_BATCH_INVALID' USING ERRCODE='22023'; END IF;
  FOR command IN SELECT value FROM jsonb_array_elements(p_commands) LOOP
    BEGIN
      IF command->>'kind'='create' THEN
        order_row:=public.create_order_for_business_day(p_store_id,(command->'params'->>'p_table_id')::uuid,
          command->'params'->'p_items',command->>'operation',(command->'params'->>'p_business_date')::date);
      ELSE
        PERFORM 1 FROM public.add_order_items_once_v1((command->'params'->>'p_order_id')::uuid,p_store_id,
          command->'params'->'p_items',command->>'operation');
      END IF;
      result:=result||jsonb_build_array(jsonb_build_object('operation',command->>'operation','status','confirmed'));
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS code=RETURNED_SQLSTATE,message=MESSAGE_TEXT;
      result:=result||jsonb_build_array(jsonb_build_object('operation',command->>'operation',
        'status',CASE WHEN code IN ('40001','40P01','55P03') THEN 'retryable' ELSE 'rejected' END,'code',code,'error',message));
    END;
  END LOOP;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.execute_order_command_batch_v1(uuid,jsonb) FROM PUBLIC,anon,service_role;
GRANT EXECUTE ON FUNCTION public.execute_order_command_batch_v1(uuid,jsonb) TO authenticated;

DO $$ BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='pos_command_private' AND c.relname='order_add_receipts' AND c.relrowsecurity)
    OR has_table_privilege('authenticated','pos_command_private.order_add_receipts','SELECT')
    OR has_function_privilege('anon','public.add_order_items_once_v1(uuid,uuid,jsonb,text)','EXECUTE')
    OR has_function_privilege('anon','public.get_order_add_receipts_v1(uuid,text[])','EXECUTE')
    OR has_function_privilege('anon','public.execute_order_command_batch_v1(uuid,jsonb)','EXECUTE') THEN
    RAISE EXCEPTION 'ORDER_ADD_RECEIPT_ACL_INVALID'; END IF;
END $$;
COMMIT;
