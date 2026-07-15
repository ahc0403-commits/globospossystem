SELECT set_config(
  'request.jwt.claim.sub',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  false
);

DO $assert$
DECLARE
  v_old public.payments%ROWTYPE;
  v_new public.payments%ROWTYPE;
  v_replay public.payments%ROWTYPE;
  v_payment_path text;
  v_legacy_hash text;
  v_verifier text;
  v_denied boolean := false;
BEGIN
  IF NOT has_function_privilege(
    'authenticated', 'public.process_payment(uuid,uuid,numeric,text)', 'EXECUTE'
  ) OR NOT has_function_privilege(
    'authenticated', 'public.process_payment(uuid,uuid,numeric,text,uuid)', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'OLD_NEW_PAYMENT_GRANTS_FAILED';
  END IF;

  SELECT * INTO v_old FROM public.process_payment(
    '30000000-0000-0000-0000-000000000001',
    '11111111-1111-1111-1111-111111111111',
    100.00,
    'CASH'
  );
  SELECT * INTO v_new FROM public.process_payment(
    '30000000-0000-0000-0000-000000000002',
    '11111111-1111-1111-1111-111111111111',
    200.00,
    'CARD',
    '40000000-0000-0000-0000-000000000002'
  );
  SELECT * INTO v_replay FROM public.process_payment(
    '30000000-0000-0000-0000-000000000002',
    '11111111-1111-1111-1111-111111111111',
    200.00,
    'CARD',
    '40000000-0000-0000-0000-000000000002'
  );
  IF v_new.id <> v_replay.id THEN
    RAISE EXCEPTION 'PAYMENT_REPLAY_CHANGED_RESULT';
  END IF;

  v_payment_path := 'tax/11111111-1111-1111-1111-111111111111/2026-07-15/' || v_new.id || '.jpg';
  PERFORM public.attach_payment_proof_v2(
    v_new.id,
    '11111111-1111-1111-1111-111111111111',
    v_payment_path,
    now()
  );
  IF NOT EXISTS (
    SELECT 1 FROM public.payments
    WHERE id = v_new.id AND proof_object_path = v_payment_path
  ) THEN
    RAISE EXCEPTION 'PROOF_V2_ATTACH_FAILED';
  END IF;

  PERFORM public.set_payroll_pin_v2(
    '11111111-1111-1111-1111-111111111111', '1234'
  );
  IF NOT public.verify_payroll_pin(
    '11111111-1111-1111-1111-111111111111', '1234'
  ) THEN
    RAISE EXCEPTION 'PIN_V2_VERIFY_FAILED';
  END IF;

  FOR i IN 1..5 LOOP
    IF public.verify_payroll_pin(
      '11111111-1111-1111-1111-111111111111', '9999'
    ) THEN
      RAISE EXCEPTION 'PIN_INVALID_ACCEPTED';
    END IF;
  END LOOP;
  BEGIN
    PERFORM public.verify_payroll_pin(
      '11111111-1111-1111-1111-111111111111', '9999'
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE '%PAYROLL_PIN_RATE_LIMITED%' THEN
      v_denied := true;
    ELSE
      RAISE;
    END IF;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'PIN_RATE_LIMIT_NOT_ENFORCED';
  END IF;

  PERFORM public.set_payroll_pin_v2(
    '11111111-1111-1111-1111-111111111111', '5678'
  );
  IF NOT public.verify_payroll_pin(
    '11111111-1111-1111-1111-111111111111', '5678'
  ) THEN
    RAISE EXCEPTION 'PIN_SUCCESS_RESET_FAILED';
  END IF;

  v_legacy_hash := encode(extensions.digest('2468', 'sha256'), 'hex');
  PERFORM public.set_payroll_pin(
    '11111111-1111-1111-1111-111111111111', v_legacy_hash
  );
  IF NOT public.verify_payroll_pin(
    '11111111-1111-1111-1111-111111111111', '2468'
  ) THEN
    RAISE EXCEPTION 'LEGACY_PIN_UPGRADE_VERIFY_FAILED';
  END IF;
  SELECT payroll_pin, payroll_pin_verifier
  INTO v_legacy_hash, v_verifier
  FROM public.restaurant_settings
  WHERE restaurant_id = '11111111-1111-1111-1111-111111111111';
  IF v_legacy_hash !~ '^[0-9a-f]{64}$' OR v_verifier NOT LIKE '$2%' THEN
    RAISE EXCEPTION 'LEGACY_PIN_UPGRADE_STORAGE_FAILED';
  END IF;

  v_denied := false;
  BEGIN
    PERFORM public.get_payroll_pin_status(
      '22222222-2222-2222-2222-222222222222'
    );
  EXCEPTION WHEN OTHERS THEN
    v_denied := true;
  END;
  IF NOT v_denied THEN
    RAISE EXCEPTION 'PIN_CROSS_STORE_ALLOWED';
  END IF;

  UPDATE public.users SET is_active = false
  WHERE auth_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  v_denied := false;
  BEGIN
    PERFORM public.get_payroll_pin_status(
      '11111111-1111-1111-1111-111111111111'
    );
  EXCEPTION WHEN OTHERS THEN
    v_denied := true;
  END;
  UPDATE public.users SET is_active = true
  WHERE auth_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  IF NOT v_denied THEN
    RAISE EXCEPTION 'PIN_INACTIVE_ACTOR_ALLOWED';
  END IF;
END;
$assert$;

-- Local pressure sample: 250 complete payment attempts are replayed once, and
-- 250 distinct actor/store PIN limiter rows are updated in place. This is not
-- a production capacity claim; it verifies bounded behavior at 10x the
-- 25-object operational cleanup batch size.
DO $pressure$
DECLARE
  v_order_id uuid;
  v_attempt_id uuid;
  v_first_payment_id uuid;
  v_replay_payment_id uuid;
BEGIN
  FOR i IN 1..250 LOOP
    v_order_id := md5('security-expand-order-' || i::text)::uuid;
    v_attempt_id := md5('security-expand-attempt-' || i::text)::uuid;
    INSERT INTO public.orders (id, restaurant_id)
    VALUES (
      v_order_id,
      '11111111-1111-1111-1111-111111111111'
    );

    SELECT id INTO v_first_payment_id
    FROM public.process_payment(
      v_order_id,
      '11111111-1111-1111-1111-111111111111',
      25.00,
      'CASH',
      v_attempt_id
    );
    SELECT id INTO v_replay_payment_id
    FROM public.process_payment(
      v_order_id,
      '11111111-1111-1111-1111-111111111111',
      25.00,
      'CASH',
      v_attempt_id
    );
    IF v_first_payment_id <> v_replay_payment_id THEN
      RAISE EXCEPTION 'PRESSURE_PAYMENT_REPLAY_CHANGED_RESULT';
    END IF;
  END LOOP;

  IF (
    SELECT count(*)
    FROM public.payment_attempts
    WHERE order_id IN (
      SELECT md5('security-expand-order-' || i::text)::uuid
      FROM generate_series(1, 250) AS pressure(i)
    )
  ) <> 250 OR (
    SELECT count(*)
    FROM public.einvoice_jobs j
    JOIN public.payments p ON p.id = j.payment_id
    WHERE p.order_id IN (
      SELECT md5('security-expand-order-' || i::text)::uuid
      FROM generate_series(1, 250) AS pressure(i)
    )
  ) <> 250 THEN
    RAISE EXCEPTION 'PRESSURE_PAYMENT_CARDINALITY_FAILED';
  END IF;

  INSERT INTO public.payroll_pin_rate_limits (
    actor_auth_id,
    store_id,
    window_started_at,
    failed_attempts,
    locked_until,
    updated_at
  )
  SELECT
    md5('security-pin-actor-' || i::text)::uuid,
    '11111111-1111-1111-1111-111111111111'::uuid,
    now(),
    1,
    NULL,
    now()
  FROM generate_series(1, 250) AS pressure(i)
  ON CONFLICT (actor_auth_id, store_id)
  DO UPDATE SET failed_attempts = 4, updated_at = now();

  INSERT INTO public.payroll_pin_rate_limits (
    actor_auth_id,
    store_id,
    window_started_at,
    failed_attempts,
    locked_until,
    updated_at
  )
  SELECT
    md5('security-pin-actor-' || i::text)::uuid,
    '11111111-1111-1111-1111-111111111111'::uuid,
    now(),
    4,
    NULL,
    now()
  FROM generate_series(1, 250) AS pressure(i)
  ON CONFLICT (actor_auth_id, store_id)
  DO UPDATE SET failed_attempts = EXCLUDED.failed_attempts,
                updated_at = EXCLUDED.updated_at;

  IF (
    SELECT count(*)
    FROM public.payroll_pin_rate_limits rate
    WHERE rate.actor_auth_id IN (
      SELECT md5('security-pin-actor-' || i::text)::uuid
      FROM generate_series(1, 250) AS pressure(i)
    )
      AND rate.store_id = '11111111-1111-1111-1111-111111111111'
      AND rate.failed_attempts = 4
  ) <> 250 THEN
    RAISE EXCEPTION 'PRESSURE_PIN_LIMITER_CARDINALITY_FAILED';
  END IF;
END;
$pressure$;
