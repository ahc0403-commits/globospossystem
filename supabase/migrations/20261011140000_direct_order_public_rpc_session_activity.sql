-- Customer list/status wrappers refresh sessions through their predecessors.
-- PostgREST must execute both POST RPCs in read-write transactions.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';

DO $fix$
DECLARE target record; before_row pg_proc%ROWTYPE; after_row pg_proc%ROWTYPE;
BEGIN
  FOR target IN SELECT * FROM (VALUES
    ('public.direct_order_public_orders_v5(uuid,text,integer)', '933d1228242d1506dad4468e9cbc8cd0'),
    ('public.direct_order_public_status_v10(uuid,text,uuid)', 'e8c04b1d2c6127020983a3aa11a52151')
  ) AS contracts(identity, source_hash) LOOP
    SELECT * INTO STRICT before_row FROM pg_proc
    WHERE oid = target.identity::regprocedure;
    IF md5(before_row.prosrc) <> target.source_hash
      OR before_row.provolatile NOT IN ('s','v') OR NOT before_row.prosecdef
      OR before_row.proconfig IS DISTINCT FROM ARRAY['search_path=public, pg_catalog']
      OR has_function_privilege('anon', before_row.oid, 'EXECUTE')
      OR has_function_privilege('authenticated', before_row.oid, 'EXECUTE')
      OR NOT has_function_privilege('service_role', before_row.oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'PUBLIC_RPC_SESSION_ACTIVITY_ANCHOR_DRIFT: %', target.identity;
    END IF;
    EXECUTE format('ALTER FUNCTION %s VOLATILE', before_row.oid::regprocedure);
    SELECT * INTO STRICT after_row FROM pg_proc WHERE oid = before_row.oid;
    IF after_row.provolatile <> 'v'
      OR (to_jsonb(before_row) - 'provolatile') IS DISTINCT FROM
         (to_jsonb(after_row) - 'provolatile') THEN
      RAISE EXCEPTION 'PUBLIC_RPC_SESSION_ACTIVITY_CHANGED_CONTRACT: %', target.identity;
    END IF;
  END LOOP;
END;
$fix$;
NOTIFY pgrst, 'reload schema';
COMMIT;
