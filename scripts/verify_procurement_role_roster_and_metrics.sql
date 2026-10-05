-- Read-only post-apply schema/ACL check; business behavior is verified by the procurement SQL suite.
BEGIN READ ONLY;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='public.procurement_role_roster'::regclass AND relrowsecurity)
 OR has_table_privilege('authenticated','public.procurement_role_roster','SELECT,INSERT,UPDATE,DELETE')
 OR has_function_privilege('anon','public.procurement_same_person(jsonb,jsonb,uuid)','EXECUTE')
 OR has_function_privilege('authenticated','public.procurement_operating_metrics(uuid,jsonb)','EXECUTE')
 OR position('PROCUREMENT_SELF_APPROVAL_FORBIDDEN' IN pg_get_functiondef('public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb)'::regprocedure))=0 THEN
  RAISE EXCEPTION 'PROCUREMENT_PRODUCTION_VERIFICATION_FAILED:procurement_role_roster_and_metrics';
 END IF;
END $$;
COMMIT;
