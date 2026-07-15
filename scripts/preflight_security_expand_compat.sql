-- Read-only preflight for 20260715020000_security_expand_compat.sql.
DO $preflight$
BEGIN
  IF pg_catalog.to_regprocedure('public.process_payment(uuid,uuid,numeric,text)') IS NULL
     OR pg_catalog.to_regprocedure('public.attach_payment_proof(uuid,uuid,text,timestamp with time zone)') IS NULL
     OR pg_catalog.to_regprocedure('public.set_payroll_pin(uuid,text)') IS NULL
     OR pg_catalog.to_regprocedure('public.clear_payroll_pin(uuid)') IS NULL THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_LEGACY_RPC_MISSING';
  END IF;

  IF pg_catalog.to_regprocedure('public.require_admin_actor_for_restaurant(uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.user_accessible_stores(uuid)') IS NULL
     OR pg_catalog.to_regprocedure('public.is_super_admin()') IS NULL THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_AUTHORIZATION_HELPER_MISSING';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_extension WHERE extname = 'pgcrypto') THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_PGCRYPTO_MISSING';
  END IF;
  IF pg_catalog.to_regprocedure('extensions.digest(text,text)') IS NULL
     OR pg_catalog.to_regprocedure('extensions.crypt(text,text)') IS NULL
     OR pg_catalog.to_regprocedure('extensions.gen_salt(text,integer)') IS NULL THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_PGCRYPTO_SCHEMA_INCOMPATIBLE';
  END IF;

  IF pg_catalog.to_regclass('public.payment_attempts') IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'payment_attempts'
         AND column_name = 'attempt_id' AND udt_name = 'uuid'
     ) THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_EXISTING_PAYMENT_ATTEMPTS_INCOMPATIBLE';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'payments'
      AND column_name = 'proof_object_path' AND udt_name <> 'text'
  ) THEN
    RAISE EXCEPTION 'SECURITY_EXPAND_EXISTING_PROOF_PATH_INCOMPATIBLE';
  END IF;
END;
$preflight$;
