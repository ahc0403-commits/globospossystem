-- Read-only post-apply schema/ACL check; business behavior is verified by the procurement SQL suite.
BEGIN READ ONLY;
DO $$ BEGIN
 IF NOT has_function_privilege('authenticated','public.procurement_workspace_page(uuid,jsonb,jsonb)','EXECUTE')
 OR has_function_privilege('anon','public.procurement_workspace_page(uuid,jsonb,jsonb)','EXECUTE') THEN
  RAISE EXCEPTION 'PROCUREMENT_PRODUCTION_VERIFICATION_FAILED:procurement_paged_reads';
 END IF;
END $$;
COMMIT;
