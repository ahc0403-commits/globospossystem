-- Read-only post-apply schema/ACL check; business behavior is verified by the procurement SQL suite.
BEGIN READ ONLY;
DO $$ BEGIN
 IF NOT has_function_privilege('service_role','public.procurement_orders_batch(uuid[],text,timestamptz,uuid,integer)','EXECUTE')
 OR has_function_privilege('authenticated','public.procurement_orders_batch(uuid[],text,timestamptz,uuid,integer)','EXECUTE')
 OR NOT has_function_privilege('service_role','public.procurement_snapshots_batch(uuid[],uuid[])','EXECUTE')
 OR has_function_privilege('authenticated','public.procurement_snapshots_batch(uuid[],uuid[])','EXECUTE')
 OR has_function_privilege('anon','public.procurement_snapshots_data(uuid[],uuid[])','EXECUTE') THEN
  RAISE EXCEPTION 'PROCUREMENT_PRODUCTION_VERIFICATION_FAILED:procurement_set_based_evidence';
 END IF;
END $$;
COMMIT;
