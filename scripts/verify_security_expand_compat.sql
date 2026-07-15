-- Read-only post-apply verification for 20260715020000.
DO $verify$
BEGIN
  IF pg_catalog.to_regclass('public.payment_attempts') IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM pg_catalog.pg_class c
       JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relname = 'payment_attempts'
         AND c.relrowsecurity AND c.relforcerowsecurity
     )
     OR has_table_privilege('authenticated', 'public.payment_attempts', 'SELECT') THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_PAYMENT_ATTEMPT_VERIFY_FAILED';
  END IF;

  IF NOT has_function_privilege(
       'authenticated', 'public.process_payment(uuid,uuid,numeric,text)', 'EXECUTE'
     ) OR NOT has_function_privilege(
       'authenticated', 'public.process_payment(uuid,uuid,numeric,text,uuid)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_PAYMENT_COMPATIBILITY_GRANT_FAILED';
  END IF;

  IF NOT has_function_privilege(
       'authenticated', 'public.attach_payment_proof(uuid,uuid,text,timestamp with time zone)', 'EXECUTE'
     ) OR NOT has_function_privilege(
       'authenticated', 'public.attach_payment_proof_v2(uuid,uuid,text,timestamp with time zone)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_PROOF_COMPATIBILITY_GRANT_FAILED';
  END IF;

  IF NOT has_function_privilege(
       'authenticated', 'public.set_payroll_pin(uuid,text)', 'EXECUTE'
     ) OR NOT has_function_privilege(
       'authenticated', 'public.set_payroll_pin_v2(uuid,text)', 'EXECUTE'
     ) OR NOT has_function_privilege(
       'authenticated', 'public.verify_payroll_pin(uuid,text)', 'EXECUTE'
     ) OR has_column_privilege(
       'authenticated', 'public.restaurant_settings', 'payroll_pin_verifier', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_PIN_COMPATIBILITY_VERIFY_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurants'
      AND column_name = 'id'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurants'
      AND column_name = 'name'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurants'
      AND column_name = 'address'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurants'
      AND column_name = 'is_active'
  ) THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_OFFICE_RESTAURANTS_CONTRACT_FAILED';
  END IF;
END;
$verify$;
