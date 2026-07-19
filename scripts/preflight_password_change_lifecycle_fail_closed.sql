DO $$
BEGIN
  IF to_regclass('auth.users') IS NULL
     OR to_regclass('public.users') IS NULL THEN
    RAISE EXCEPTION 'PASSWORD_CHANGE_LIFECYCLE_RELATION_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'users'
      AND column_name = 'must_change_password'
      AND is_nullable = 'NO'
  ) THEN
    RAISE EXCEPTION 'PASSWORD_CHANGE_LIFECYCLE_GATE_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'users'
      AND column_name = 'password_change_generation'
  ) THEN
    RAISE EXCEPTION 'PASSWORD_CHANGE_LIFECYCLE_PARTIAL_STATE_PRESENT';
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
    RAISE EXCEPTION 'PASSWORD_CHANGE_LIFECYCLE_PREDECESSOR_TRIGGER_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.users profile
    LEFT JOIN auth.users identity ON identity.id = profile.auth_id
    WHERE profile.is_active
      AND (identity.id IS NULL OR identity.encrypted_password IS NULL)
  ) THEN
    RAISE EXCEPTION 'PASSWORD_CHANGE_LIFECYCLE_ACTIVE_IDENTITY_NOT_READY';
  END IF;
END $$;
