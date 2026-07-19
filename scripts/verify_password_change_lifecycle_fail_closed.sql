DO $$
DECLARE
  trigger_definition text;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'users'
      AND column_name = 'password_change_generation'
      AND data_type = 'bigint'
      AND is_nullable = 'NO'
      AND column_default = '0'
  ) THEN
    RAISE EXCEPTION 'PASSWORD_CHANGE_GENERATION_COLUMN_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    JOIN pg_class relation ON relation.oid = trigger_row.tgrelid
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'auth'
      AND relation.relname = 'users'
      AND trigger_row.tgname = 'clear_pos_initial_password_requirement'
      AND NOT trigger_row.tgisinternal
  ) OR to_regprocedure('public.clear_pos_initial_password_requirement()') IS NOT NULL THEN
    RAISE EXCEPTION 'PASSWORD_CHANGE_FAIL_OPEN_TRIGGER_REMAINS';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    JOIN pg_class relation ON relation.oid = trigger_row.tgrelid
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'auth'
      AND relation.relname = 'users'
      AND trigger_row.tgname = 'arm_pos_password_change_requirement'
      AND trigger_row.tgenabled = 'O'
      AND NOT trigger_row.tgisinternal
  ) THEN
    RAISE EXCEPTION 'PASSWORD_CHANGE_FAIL_CLOSED_TRIGGER_MISSING';
  END IF;

  IF to_regprocedure('public.arm_pos_password_change_requirement()') IS NULL THEN
    RAISE EXCEPTION 'PASSWORD_CHANGE_FAIL_CLOSED_FUNCTION_MISSING';
  END IF;

  SELECT pg_get_functiondef('public.arm_pos_password_change_requirement()'::regprocedure)
  INTO trigger_definition;
  IF position('must_change_password = true' IN trigger_definition) = 0
     OR position('password_change_generation + 1' IN trigger_definition) = 0 THEN
    RAISE EXCEPTION 'PASSWORD_CHANGE_FAIL_CLOSED_FUNCTION_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.users
    WHERE is_active
      AND (
        NOT must_change_password
        OR password_change_required_at IS NULL
      )
  ) THEN
    RAISE EXCEPTION 'PASSWORD_CHANGE_ACTIVE_PROFILE_NOT_REARMED';
  END IF;

  IF has_table_privilege('anon', 'public.users', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.users', 'UPDATE') THEN
    RAISE EXCEPTION 'PASSWORD_CHANGE_CLIENT_UPDATE_PRIVILEGE_PRESENT';
  END IF;

  IF has_function_privilege(
       'anon',
       'public.arm_pos_password_change_requirement()',
       'EXECUTE'
     ) OR has_function_privilege(
       'authenticated',
       'public.arm_pos_password_change_requirement()',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PASSWORD_CHANGE_TRIGGER_FUNCTION_EXECUTABLE_BY_CLIENT';
  END IF;
END $$;
