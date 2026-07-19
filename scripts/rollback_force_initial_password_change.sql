BEGIN;

DROP TRIGGER IF EXISTS clear_pos_initial_password_requirement
  ON auth.users;
DROP FUNCTION IF EXISTS public.clear_pos_initial_password_requirement();

UPDATE public.users
SET must_change_password = false,
    password_change_required_at = NULL
WHERE must_change_password;

ALTER TABLE public.users
  ALTER COLUMN must_change_password SET DEFAULT false,
  ALTER COLUMN password_change_required_at DROP DEFAULT;

COMMIT;
