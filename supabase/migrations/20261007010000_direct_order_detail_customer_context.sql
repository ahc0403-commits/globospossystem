-- Version the response so existing strict v3 customers keep working.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '30s';

CREATE FUNCTION public.direct_order_public_status_v4(
  p_session_id uuid, p_secret_hash text, p_request_id uuid
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_catalog AS $$
DECLARE v_base jsonb; v_customer jsonb;
BEGIN
  -- Validate the secret and request ownership before touching customer PII.
  v_base := public.direct_order_public_status_v3(
    p_session_id, p_secret_hash, p_request_id
  );
  SELECT CASE WHEN r.pii_purged_at IS NOT NULL THEN NULL ELSE
    jsonb_build_object(
      'customer_name', a.customer_name,
      'customer_phone', a.customer_phone,
      'formatted_address', a.formatted_address,
      'detail_address', a.detail_address,
      'district', a.district,
      'ward', a.ward,
      'customer_note', r.customer_note
    ) END INTO v_customer
  FROM public.direct_order_requests r
  LEFT JOIN public.direct_order_request_addresses a ON a.request_id = r.id
  WHERE r.id = p_request_id AND r.session_id = p_session_id;
  RETURN v_base || jsonb_build_object('customer', v_customer);
END;
$$;
REVOKE ALL ON FUNCTION public.direct_order_public_status_v4(uuid,text,uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_status_v4(uuid,text,uuid)
  TO service_role;
COMMENT ON FUNCTION public.direct_order_public_status_v4(uuid,text,uuid) IS
  'Owning-session v3 detail plus explicit stored customer contact/address/order note; purged PII stays unavailable. No per-item reads.';

DO $$ BEGIN
  IF has_function_privilege('anon','public.direct_order_public_status_v4(uuid,text,uuid)','EXECUTE')
    OR has_function_privilege('authenticated','public.direct_order_public_status_v4(uuid,text,uuid)','EXECUTE')
    OR NOT has_function_privilege('service_role','public.direct_order_public_status_v4(uuid,text,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_DETAIL_PRIVILEGES_INVALID';
  END IF;
END $$;
COMMIT;
