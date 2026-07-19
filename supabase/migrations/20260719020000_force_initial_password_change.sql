-- Every POS identity starts with a temporary administrator-issued password.
-- Keep the completion signal server-owned: the flag is cleared only when
-- Supabase Auth replaces auth.users.encrypted_password.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS must_change_password boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS password_change_required_at timestamptz,
  ADD COLUMN IF NOT EXISTS password_changed_at timestamptz;

UPDATE public.users
SET password_change_required_at = COALESCE(
  password_change_required_at,
  clock_timestamp()
)
WHERE must_change_password;

ALTER TABLE public.users
  ALTER COLUMN password_change_required_at SET DEFAULT clock_timestamp();

COMMENT ON COLUMN public.users.must_change_password IS
  'Server-owned gate that blocks POS routes until the account replaces its temporary password.';
COMMENT ON COLUMN public.users.password_change_required_at IS
  'Time at which the current administrator-issued password became temporary.';
COMMENT ON COLUMN public.users.password_changed_at IS
  'Most recent time Supabase Auth confirmed a password hash replacement for this POS profile.';

CREATE OR REPLACE FUNCTION public.clear_pos_initial_password_requirement()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF OLD.encrypted_password IS DISTINCT FROM NEW.encrypted_password THEN
    UPDATE public.users
    SET must_change_password = false,
        password_change_required_at = NULL,
        password_changed_at = clock_timestamp()
    WHERE auth_id = NEW.id
      AND must_change_password;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.clear_pos_initial_password_requirement()
  FROM PUBLIC, anon, authenticated, service_role;

DROP TRIGGER IF EXISTS clear_pos_initial_password_requirement
  ON auth.users;
CREATE TRIGGER clear_pos_initial_password_requirement
AFTER UPDATE OF encrypted_password ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.clear_pos_initial_password_requirement();

-- No client role may directly rewrite the profile or the server-owned gate.
-- POS profile writes already use SECURITY DEFINER RPCs; service_role retains
-- its administrative access for provisioning and password rotation.
REVOKE UPDATE ON public.users FROM anon, authenticated;
