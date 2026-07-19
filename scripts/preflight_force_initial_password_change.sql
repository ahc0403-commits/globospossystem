DO $$
BEGIN
  IF to_regclass('auth.users') IS NULL
     OR to_regclass('public.users') IS NULL THEN
    RAISE EXCEPTION 'INITIAL_PASSWORD_CHANGE_RELATION_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.users WHERE is_active
  ) THEN
    RAISE EXCEPTION 'INITIAL_PASSWORD_CHANGE_NO_ACTIVE_POS_PROFILE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.users profile
    LEFT JOIN auth.users identity ON identity.id = profile.auth_id
    WHERE profile.is_active
      AND (identity.id IS NULL OR identity.encrypted_password IS NULL)
  ) THEN
    RAISE EXCEPTION 'INITIAL_PASSWORD_CHANGE_ACTIVE_IDENTITY_NOT_PASSWORD_READY';
  END IF;
END $$;
