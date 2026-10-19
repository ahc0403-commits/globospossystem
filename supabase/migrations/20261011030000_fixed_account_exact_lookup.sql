BEGIN;
-- Reuse Supabase Auth users_instance_id_email_idx. Auth owns this table;
-- a normal postgres migration role must not try to create its indexes.
DO $$ BEGIN
  IF NOT EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='auth' AND tablename='users'
    AND indexname='users_instance_id_email_idx') THEN RAISE EXCEPTION 'FIXED_ACCOUNT_AUTH_INDEX_REQUIRED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='auth' AND table_name='users'
    AND column_name='is_sso_user') THEN RAISE EXCEPTION 'FIXED_ACCOUNT_AUTH_SCHEMA_REQUIRED'; END IF;
END $$;
CREATE OR REPLACE FUNCTION public.find_fixed_account_auth_user(p_email text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public, auth, pg_catalog AS $$
DECLARE v_result jsonb;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'FIXED_ACCOUNT_SERVICE_REQUIRED'; END IF;
  IF p_email IS NULL OR length(btrim(p_email)) NOT BETWEEN 3 AND 254 THEN RAISE EXCEPTION 'FIXED_ACCOUNT_EMAIL_INVALID'; END IF;
  SELECT jsonb_build_object('id',id,'email',email) INTO v_result
  FROM auth.users WHERE instance_id='00000000-0000-0000-0000-000000000000'::uuid
    AND lower(email)=lower(btrim(p_email)) AND is_sso_user=false ORDER BY id LIMIT 1;
  RETURN v_result;
END $$;
REVOKE ALL ON FUNCTION public.find_fixed_account_auth_user(text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.find_fixed_account_auth_user(text) TO service_role;
COMMIT;
