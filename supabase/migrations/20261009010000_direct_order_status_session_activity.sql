-- Status reads refresh session last_seen_at through the v4 -> v1 chain.
-- PostgREST must therefore run this RPC in a read-write transaction.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';

DO $fix$
DECLARE before_row pg_proc%ROWTYPE; after_row pg_proc%ROWTYPE;
BEGIN
  SELECT * INTO STRICT before_row FROM pg_proc
  WHERE oid = 'public.direct_order_public_status_v5(uuid,text,uuid)'::regprocedure;
  IF md5(before_row.prosrc) <> '742d56d41d4b2520149a95c5b64074b9'
    OR before_row.provolatile NOT IN ('s','v') OR NOT before_row.prosecdef
    OR before_row.proconfig IS DISTINCT FROM ARRAY['search_path=public, pg_catalog']
    OR has_function_privilege('anon', before_row.oid, 'EXECUTE')
    OR has_function_privilege('authenticated', before_row.oid, 'EXECUTE')
    OR NOT has_function_privilege('service_role', before_row.oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_STATUS_SESSION_ACTIVITY_ANCHOR_DRIFT';
  END IF;
  ALTER FUNCTION public.direct_order_public_status_v5(uuid,text,uuid) VOLATILE;
  SELECT * INTO STRICT after_row FROM pg_proc WHERE oid = before_row.oid;
  IF after_row.provolatile <> 'v'
    OR (to_jsonb(before_row) - 'provolatile') IS DISTINCT FROM
       (to_jsonb(after_row) - 'provolatile') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_STATUS_SESSION_ACTIVITY_CHANGED_CONTRACT';
  END IF;
END;
$fix$;
NOTIFY pgrst, 'reload schema';
COMMIT;
