\set ON_ERROR_STOP on

DO $$
DECLARE
  v_active_count integer;
  v_inactive_count integer;
  v_audit_count integer;
  v_wrapper_security_definer boolean;
  v_internal_security_definer boolean;
BEGIN
  IF to_regprocedure(
       'public.admin_purge_inactive_store(uuid,text)'
     ) IS NULL
     OR to_regprocedure(
       'public._purge_inactive_store_data(uuid,text,uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'ADMIN_STORE_PURGE_VERIFY_FUNCTION_MISSING';
  END IF;

  SELECT prosecdef INTO v_wrapper_security_definer
  FROM pg_proc
  WHERE oid = 'public.admin_purge_inactive_store(uuid,text)'::regprocedure;

  SELECT prosecdef INTO v_internal_security_definer
  FROM pg_proc
  WHERE oid = 'public._purge_inactive_store_data(uuid,text,uuid)'::regprocedure;

  IF NOT v_wrapper_security_definer OR v_internal_security_definer THEN
    RAISE EXCEPTION 'ADMIN_STORE_PURGE_VERIFY_SECURITY_MODE';
  END IF;

  IF has_function_privilege(
       'anon', 'public.admin_purge_inactive_store(uuid,text)', 'EXECUTE'
     )
     OR has_function_privilege(
       'service_role', 'public.admin_purge_inactive_store(uuid,text)', 'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated', 'public.admin_purge_inactive_store(uuid,text)', 'EXECUTE'
     )
     OR has_function_privilege(
       'anon', 'public._purge_inactive_store_data(uuid,text,uuid)', 'EXECUTE'
     )
     OR has_function_privilege(
       'authenticated', 'public._purge_inactive_store_data(uuid,text,uuid)', 'EXECUTE'
     )
     OR has_function_privilege(
       'service_role', 'public._purge_inactive_store_data(uuid,text,uuid)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'ADMIN_STORE_PURGE_VERIFY_FUNCTION_ACL';
  END IF;

  SELECT count(*) FILTER (WHERE is_active),
         count(*) FILTER (WHERE NOT is_active)
  INTO v_active_count, v_inactive_count
  FROM public.restaurants;

  IF v_active_count <> 7 OR v_inactive_count <> 0 THEN
    RAISE EXCEPTION
      'ADMIN_STORE_PURGE_VERIFY_SHAPE active=% inactive=%',
      v_active_count,
      v_inactive_count;
  END IF;

  IF (SELECT count(*) FROM public.users) <> 14
     OR (SELECT count(*) FROM public.users WHERE is_active) <> 14 THEN
    RAISE EXCEPTION 'ADMIN_STORE_PURGE_VERIFY_OPERATIONAL_PROFILE_COUNT';
  END IF;

  IF (
    SELECT count(*)
    FROM public.audit_logs
    WHERE action = 'admin_purge_inactive_store_profile'
      AND created_at >= now() - interval '10 minutes'
  ) <> 21 THEN
    RAISE EXCEPTION 'ADMIN_STORE_PURGE_VERIFY_PROFILE_AUDIT_COUNT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.restaurants
    WHERE id = '0446a7e2-97d3-6a53-929c-c1849a3d12c3'::uuid
       OR slug = 'smoke-in-saigon-bowl-2'
  ) THEN
    RAISE EXCEPTION 'ADMIN_STORE_PURGE_VERIFY_TARGET_REMAINS';
  END IF;

  SELECT count(*) INTO v_audit_count
  FROM public.audit_logs
  WHERE action = 'admin_purge_inactive_store'
    AND created_at >= now() - interval '10 minutes';

  IF v_audit_count <> 23 THEN
    RAISE EXCEPTION 'ADMIN_STORE_PURGE_VERIFY_AUDIT_COUNT: %', v_audit_count;
  END IF;
END $$;

SELECT 'ADMIN_STORE_PURGE_VERIFY_OK' AS result;
