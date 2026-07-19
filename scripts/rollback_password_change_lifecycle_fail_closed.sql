BEGIN;

DROP TRIGGER IF EXISTS arm_pos_password_change_requirement
  ON auth.users;
DROP FUNCTION IF EXISTS public.arm_pos_password_change_requirement();

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

CREATE TRIGGER clear_pos_initial_password_requirement
AFTER UPDATE OF encrypted_password ON auth.users
FOR EACH ROW
EXECUTE FUNCTION public.clear_pos_initial_password_requirement();

ALTER TABLE public.users
  DROP COLUMN IF EXISTS password_change_generation;

COMMIT;
