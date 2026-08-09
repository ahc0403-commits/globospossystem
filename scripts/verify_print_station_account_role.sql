DO $verify$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.print_routing_actor_can_run(uuid)'::regprocedure
  ) INTO v_definition;

  IF position('print_station' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'PRINT_STATION_ROLE_VERIFY_QUEUE_PERMISSION_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.users'::regclass
      AND conname = 'users_role_check'
      AND pg_get_constraintdef(oid) LIKE '%print_station%'
  ) OR NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.users'::regclass
      AND conname = 'users_account_type_check'
      AND pg_get_constraintdef(oid) LIKE '%device_print_station%'
  ) THEN
    RAISE EXCEPTION 'PRINT_STATION_ROLE_VERIFY_USER_CONSTRAINT_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.store_fixed_account_requirements
    WHERE store_id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
      AND account_code = 'print'
      AND account_type = 'device_print_station'
      AND role = 'print_station'
      AND scope = 'store'
      AND is_active = true
  ) THEN
    RAISE EXCEPTION 'PRINT_STATION_ROLE_VERIFY_REQUIREMENT_MISSING';
  END IF;
END;
$verify$;
