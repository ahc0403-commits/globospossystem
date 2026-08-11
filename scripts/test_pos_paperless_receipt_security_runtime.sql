\set ON_ERROR_STOP on

BEGIN;

DO $test$
DECLARE
  v_store_id uuid;
  v_auth_id uuid := gen_random_uuid();
  v_order_id uuid := gen_random_uuid();
  v_receipt_id uuid := gen_random_uuid();
  v_result jsonb;
  v_token text;
  v_old_token constant text := 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
  v_allowed boolean;
  v_presented_at timestamptz;
  v_presented_again timestamptz;
  v_active_links integer;
  v_index integer;
BEGIN
  SELECT id INTO v_store_id
  FROM public.restaurants
  WHERE is_active = true
  ORDER BY id
  LIMIT 1;
  IF v_store_id IS NULL THEN
    RAISE EXCEPTION 'SECURITY_FIXTURE_ACTIVE_STORE_REQUIRED';
  END IF;

  INSERT INTO auth.users (id) VALUES (v_auth_id);
  INSERT INTO public.users (
    auth_id, restaurant_id, role, full_name, is_active,
    account_type, fixed_account_code, must_change_password
  ) VALUES (
    v_auth_id, v_store_id, 'super_admin', 'Receipt Security Fixture', true,
    'master', 'receipt_security', false
  );
  PERFORM set_config('request.jwt.claim.sub', v_auth_id::text, true);

  INSERT INTO public.orders (id, restaurant_id, status)
  VALUES (v_order_id, v_store_id, 'completed');
  INSERT INTO public.digital_receipts (
    id, restaurant_id, order_id, receipt_number, snapshot
  ) VALUES (
    v_receipt_id, v_store_id, v_order_id, 'SECURITY-FIXTURE',
    jsonb_build_object('receipt_number', 'SECURITY-FIXTURE')
  );

  FOR v_index IN 1..4 LOOP
    v_result := public.issue_digital_receipt_link(v_receipt_id);
    IF v_index = 4 THEN v_token := v_result->>'token'; END IF;
  END LOOP;
  SELECT count(*)::integer INTO v_active_links
  FROM public.digital_receipt_links
  WHERE digital_receipt_id = v_receipt_id
    AND revoked_at IS NULL
    AND expires_at > now();
  IF v_active_links <> 3 THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_ACTIVE_LINK_CAP_FAILED count=%',
      v_active_links;
  END IF;

  IF public.get_public_receipt(v_token)->>'receipt_number'
     IS DISTINCT FROM 'SECURITY-FIXTURE' THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_VALID_LOOKUP_FAILED';
  END IF;
  SELECT last_presented_at INTO v_presented_at
  FROM public.digital_receipt_links
  WHERE token_hash = extensions.digest(v_token, 'sha256');
  PERFORM public.get_public_receipt(v_token);
  SELECT last_presented_at INTO v_presented_again
  FROM public.digital_receipt_links
  WHERE token_hash = extensions.digest(v_token, 'sha256');
  IF v_presented_again IS DISTINCT FROM v_presented_at THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_PRESENTATION_WRITE_NOT_THROTTLED';
  END IF;

  INSERT INTO public.digital_receipt_links (
    digital_receipt_id, token_hash, created_at, expires_at
  ) VALUES (
    v_receipt_id,
    extensions.digest(v_old_token, 'sha256'),
    now() - interval '121 days',
    now() - interval '31 days'
  );
  IF public.get_public_receipt(v_old_token) IS NOT NULL THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_EXPIRED_LINK_ACCEPTED';
  END IF;
  PERFORM public.cleanup_digital_receipt_security_state(1000);
  IF EXISTS (
    SELECT 1 FROM public.digital_receipt_links
    WHERE token_hash = extensions.digest(v_old_token, 'sha256')
  ) THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_EXPIRED_HASH_NOT_CLEANED';
  END IF;

  FOR v_index IN 1..30 LOOP
    v_allowed := public.consume_digital_receipt_rate_limit(
      repeat('a', 64)
    );
    IF NOT v_allowed THEN
      RAISE EXCEPTION 'DIGITAL_RECEIPT_RATE_LIMIT_EARLY_BLOCK request=%',
        v_index;
    END IF;
  END LOOP;
  IF public.consume_digital_receipt_rate_limit(repeat('a', 64)) THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_RATE_LIMIT_OVERFLOW_ALLOWED';
  END IF;

  IF has_function_privilege(
       'anon', 'public.get_public_receipt(text)', 'EXECUTE'
     ) OR has_function_privilege(
       'authenticated', 'public.get_public_receipt(text)', 'EXECUTE'
     ) OR NOT has_function_privilege(
       'service_role', 'public.get_public_receipt(text)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'DIGITAL_RECEIPT_RPC_PRIVILEGE_BOUNDARY_FAILED';
  END IF;
END;
$test$;

ROLLBACK;

SELECT 'PAPERLESS_RECEIPT_SECURITY_RUNTIME_OK' AS result;
