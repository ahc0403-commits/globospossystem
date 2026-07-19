DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'users'
      AND column_name = 'must_change_password'
      AND is_nullable = 'NO'
      AND column_default ILIKE '%true%'
  ) THEN
    RAISE EXCEPTION 'INITIAL_PASSWORD_CHANGE_FLAG_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    JOIN pg_class relation ON relation.oid = trigger_row.tgrelid
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'auth'
      AND relation.relname = 'users'
      AND trigger_row.tgname = 'clear_pos_initial_password_requirement'
      AND trigger_row.tgenabled = 'O'
      AND NOT trigger_row.tgisinternal
  ) THEN
    RAISE EXCEPTION 'INITIAL_PASSWORD_CHANGE_TRIGGER_MISSING';
  END IF;

  IF to_regprocedure('public.clear_pos_initial_password_requirement()') IS NULL THEN
    RAISE EXCEPTION 'INITIAL_PASSWORD_CHANGE_FUNCTION_MISSING';
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
    RAISE EXCEPTION 'INITIAL_PASSWORD_CHANGE_ACTIVE_PROFILE_NOT_GATED';
  END IF;

  IF has_table_privilege('anon', 'public.users', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.users', 'UPDATE') THEN
    RAISE EXCEPTION 'INITIAL_PASSWORD_CHANGE_CLIENT_UPDATE_PRIVILEGE_PRESENT';
  END IF;
END $$;
