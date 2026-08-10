DO $preflight$
BEGIN
  IF to_regclass('public.orders') IS NULL
     OR to_regclass('public.order_items') IS NULL
     OR to_regclass('public.print_jobs') IS NULL
     OR to_regclass('public.store_fixed_account_requirements') IS NULL THEN
    RAISE EXCEPTION 'EMERGENCY_FULFILMENT_BASE_TABLES_MISSING';
  END IF;

  IF to_regprocedure('public.claim_print_jobs(uuid,integer)') IS NULL
     OR to_regprocedure(
       'public.admin_configure_store_workforce(uuid,text,text,integer,jsonb)'
     ) IS NULL THEN
    RAISE EXCEPTION 'EMERGENCY_FULFILMENT_BASE_FUNCTIONS_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM vault.decrypted_secrets
    WHERE name IN ('cron_secret', 'app.settings.cron_secret')
      AND decrypted_secret IS NOT NULL
      AND length(decrypted_secret) >= 16
  ) THEN
    RAISE EXCEPTION 'EMERGENCY_CRON_SECRET_MISSING';
  END IF;
END;
$preflight$;
