DO $preflight$
BEGIN
  IF to_regclass('public.printer_destinations') IS NULL
     OR to_regclass('public.print_jobs') IS NULL THEN
    RAISE EXCEPTION 'PRINT_CONFIGURATION_BASE_TABLES_MISSING';
  END IF;

  IF to_regprocedure('public.require_admin_actor_for_restaurant(uuid)') IS NULL
     OR to_regprocedure('public.user_accessible_stores(uuid)') IS NULL THEN
    RAISE EXCEPTION 'PRINT_CONFIGURATION_AUTHORIZATION_BASE_MISSING';
  END IF;
END;
$preflight$;
