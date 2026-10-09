BEGIN READ ONLY;
DO $preflight$
DECLARE target oid := to_regprocedure('public.direct_order_public_status_v5(uuid,text,uuid)');
BEGIN
  IF target IS NULL OR NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = target
    AND provolatile = 's' AND prosecdef
    AND md5(prosrc) = '742d56d41d4b2520149a95c5b64074b9'
    AND proconfig = ARRAY['search_path=public, pg_catalog'])
    OR has_function_privilege('anon', target, 'EXECUTE')
    OR has_function_privilege('authenticated', target, 'EXECUTE')
    OR NOT has_function_privilege('service_role', target, 'EXECUTE') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_STATUS_SESSION_ACTIVITY_PREFLIGHT_FAILED';
  END IF;
END;
$preflight$;
ROLLBACK;
SELECT 'DIRECT_ORDER_STATUS_SESSION_ACTIVITY_PREFLIGHT=PASS';
