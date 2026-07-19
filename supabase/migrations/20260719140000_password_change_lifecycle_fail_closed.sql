-- Treat every Auth password write as an administrator-issued credential until
-- an authenticated POS user completes the dedicated password-change flow.
-- The generation counter prevents a concurrent administrator reset from being
-- cleared by an older self-service request.

ALTER TABLE public.users
  ADD COLUMN IF NOT EXISTS password_change_generation bigint NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.users.password_change_generation IS
  'Monotonic server-owned generation incremented for every auth.users password hash replacement.';

DROP TRIGGER IF EXISTS clear_pos_initial_password_requirement
  ON auth.users;
DROP FUNCTION IF EXISTS public.clear_pos_initial_password_requirement();

CREATE OR REPLACE FUNCTION public.arm_pos_password_change_requirement()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF OLD.encrypted_password IS DISTINCT FROM NEW.encrypted_password THEN
    UPDATE public.users
    SET must_change_password = true,
        password_change_required_at = clock_timestamp(),
        password_change_generation = password_change_generation + 1
    WHERE auth_id = NEW.id;
  END IF;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.arm_pos_password_change_requirement()
  FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER arm_pos_password_change_requirement
AFTER UPDATE OF encrypted_password ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.arm_pos_password_change_requirement();

-- This release intentionally re-arms every active operational profile. Existing
-- passwords remain valid, but no active account may enter POS operations until
-- it completes the explicit self-service change flow.
UPDATE public.users
SET must_change_password = true,
    password_change_required_at = COALESCE(
      password_change_required_at,
      clock_timestamp()
    )
WHERE is_active;

REVOKE UPDATE ON public.users FROM anon, authenticated;
