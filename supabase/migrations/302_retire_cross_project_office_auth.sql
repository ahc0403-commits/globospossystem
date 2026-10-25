-- Close the legacy numbered Office migration tail on a fresh POS install.
-- These historical records remain replayable, but POS Auth must never provision
-- Office identity records. Office runs in its own Supabase project.
-- No identity, password, workforce record or business row is changed here.
BEGIN;
DO $retire_office_auth_trigger$
DECLARE legacy_trigger text;
BEGIN
 SELECT trigger_row.tgname INTO legacy_trigger
 FROM pg_trigger trigger_row JOIN pg_proc routine ON routine.oid=trigger_row.tgfoid
 JOIN pg_namespace namespace ON namespace.oid=routine.pronamespace
 WHERE trigger_row.tgrelid='auth.users'::regclass AND NOT trigger_row.tgisinternal
   AND namespace.nspname='public' AND routine.proname='handle_new_office_user';
 IF legacy_trigger IS NOT NULL THEN
   EXECUTE format('DROP TRIGGER %I ON auth.users',legacy_trigger);
 END IF;
 IF EXISTS(SELECT 1 FROM pg_trigger trigger_row JOIN pg_proc routine ON routine.oid=trigger_row.tgfoid
   WHERE trigger_row.tgrelid='auth.users'::regclass AND NOT trigger_row.tgisinternal
     AND routine.proname='handle_new_office_user') THEN
   RAISE EXCEPTION 'POS_OFFICE_AUTH_TRIGGER_STILL_ACTIVE';
 END IF;
END $retire_office_auth_trigger$;

-- Preserve the actual historical tables and functions as private evidence.
-- An Office UUID or business-record identifier does not authorize a POS login.
REVOKE ALL ON public.office_user_profiles FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.handle_new_office_user() FROM PUBLIC,anon,authenticated,service_role;

-- Only POS's public API is exposed. Office schemas belong to its own project;
-- native SECURITY DEFINER POS bridge routines retain their original privileges.
ALTER ROLE authenticator SET pgrst.db_schemas='public';
NOTIFY pgrst,'reload config';

DO $verify$
BEGIN
 IF has_table_privilege('anon','public.office_user_profiles','SELECT,INSERT,UPDATE,DELETE')
   OR has_table_privilege('authenticated','public.office_user_profiles','SELECT,INSERT,UPDATE,DELETE')
   OR has_table_privilege('service_role','public.office_user_profiles','SELECT,INSERT,UPDATE,DELETE') THEN
   RAISE EXCEPTION 'POS_OFFICE_AUTH_TABLE_STILL_EXPOSED';
 END IF;
 IF EXISTS(SELECT 1 FROM pg_trigger trigger_row WHERE trigger_row.tgrelid='auth.users'::regclass
   AND NOT trigger_row.tgisinternal AND trigger_row.tgfoid='public.handle_new_office_user()'::regprocedure) THEN
   RAISE EXCEPTION 'POS_OFFICE_AUTH_TRIGGER_STILL_ACTIVE';
 END IF;
END $verify$;
COMMIT;
