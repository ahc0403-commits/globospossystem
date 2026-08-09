DO $preflight$
BEGIN
  IF to_regclass('public.users') IS NULL
     OR to_regclass('public.store_fixed_account_requirements') IS NULL
     OR to_regprocedure('public.print_routing_actor_can_run(uuid)') IS NULL THEN
    RAISE EXCEPTION 'PRINT_STATION_ROLE_PREFLIGHT_DEPENDENCY_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurants
    WHERE id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'PRINT_STATION_ROLE_PREFLIGHT_STORE_UNAVAILABLE';
  END IF;

  IF EXISTS (
    SELECT 1 FROM auth.users WHERE lower(email) = 'print@globos.world'
  ) OR EXISTS (
    SELECT 1 FROM public.users WHERE lower(fixed_account_code) = 'print'
  ) OR EXISTS (
    SELECT 1
    FROM public.store_fixed_account_requirements
    WHERE lower(account_code) = 'print'
  ) THEN
    RAISE EXCEPTION 'PRINT_STATION_ROLE_PREFLIGHT_IDENTITY_CONFLICT';
  END IF;
END;
$preflight$;
