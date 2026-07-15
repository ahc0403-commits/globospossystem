SELECT set_config(
  'request.jwt.claim.sub',
  'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  false
);

DO $assert$
DECLARE
  v_payment public.payments%ROWTYPE;
  v_path text;
BEGIN
  IF has_function_privilege(
    'authenticated', 'public.process_payment(uuid,uuid,numeric,text)', 'EXECUTE'
  ) OR has_function_privilege(
    'authenticated', 'public.attach_payment_proof(uuid,uuid,text,timestamp with time zone)', 'EXECUTE'
  ) OR has_function_privilege(
    'authenticated', 'public.set_payroll_pin(uuid,text)', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'CONTRACT_LEGACY_GRANT_REMAINS';
  END IF;
  IF NOT has_function_privilege(
    'authenticated', 'public.process_payment(uuid,uuid,numeric,text,uuid)', 'EXECUTE'
  ) OR NOT has_function_privilege(
    'authenticated', 'public.attach_payment_proof_v2(uuid,uuid,text,timestamp with time zone)', 'EXECUTE'
  ) OR NOT has_function_privilege(
    'authenticated', 'public.set_payroll_pin_v2(uuid,text)', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'CONTRACT_V2_GRANT_MISSING';
  END IF;

  SELECT * INTO v_payment FROM public.process_payment(
    '30000000-0000-0000-0000-000000000004',
    '11111111-1111-1111-1111-111111111111',
    400.00,
    'CASH',
    '40000000-0000-0000-0000-000000000004'
  );
  v_path := 'tax/11111111-1111-1111-1111-111111111111/2026-07-15/' || v_payment.id || '.jpg';
  PERFORM public.attach_payment_proof_v2(
    v_payment.id,
    '11111111-1111-1111-1111-111111111111',
    v_path,
    now()
  );
  PERFORM public.set_payroll_pin_v2(
    '11111111-1111-1111-1111-111111111111', '1357'
  );
  IF NOT public.verify_payroll_pin(
    '11111111-1111-1111-1111-111111111111', '1357'
  ) THEN
    RAISE EXCEPTION 'CONTRACT_NEW_CLIENT_PIN_FAILED';
  END IF;
END;
$assert$;
