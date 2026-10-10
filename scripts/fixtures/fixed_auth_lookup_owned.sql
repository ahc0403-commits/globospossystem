-- Disposable Supabase 17 DB only; use its actual managed auth schema/index.
DO $$ BEGIN
  IF current_database()<>'payroll_test' THEN RAISE EXCEPTION 'FIXTURE_DATABASE_REQUIRED'; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='auth.users'::regclass AND pg_get_userbyid(relowner)='supabase_auth_admin') THEN RAISE EXCEPTION 'AUTH_OWNER_FIXTURE_MISMATCH'; END IF;
  IF NOT EXISTS(SELECT 1 FROM pg_indexes WHERE schemaname='auth' AND tablename='users' AND indexname='users_instance_id_email_idx') THEN RAISE EXCEPTION 'AUTH_INDEX_FIXTURE_MISSING'; END IF;
END $$;
-- The database image has the bootstrap Auth schema; GoTrue normally adds this
-- column. Extend only this disposable fixture to the current managed contract.
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS is_sso_user boolean NOT NULL DEFAULT false;
INSERT INTO auth.users(id,email,instance_id,is_sso_user)
VALUES('00000000-0000-4000-8000-000000000001','OWNED@EXAMPLE.INVALID','00000000-0000-0000-0000-000000000000',false);
