-- Keep the v4 action usable for already loaded clients, without new PII.
-- No business/customer records are changed or removed.
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';
CREATE OR REPLACE FUNCTION public.direct_order_public_status_v4(
  p_session_id uuid, p_secret_hash text, p_request_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_catalog AS $$
BEGIN
  RETURN public.direct_order_public_status_v3(p_session_id,p_secret_hash,p_request_id)
    || jsonb_build_object('customer',NULL);
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_public_status_v4(uuid,text,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_status_v4(uuid,text,uuid)
  TO service_role;
COMMIT;
