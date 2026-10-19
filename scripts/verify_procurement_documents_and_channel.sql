-- Read-only post-apply schema/ACL check; business behavior is verified by the procurement SQL suite.
BEGIN READ ONLY;
DO $$ BEGIN
 IF to_regprocedure('public.record_procurement_document(uuid,text,uuid,text,text,text,text,integer,jsonb)') IS NULL
 OR NOT has_function_privilege('authenticated','public.procurement_document_data(uuid,text,uuid,text,jsonb)','EXECUTE')
 OR has_function_privilege('anon','public.procurement_document_data(uuid,text,uuid,text,jsonb)','EXECUTE') THEN
  RAISE EXCEPTION 'PROCUREMENT_PRODUCTION_VERIFICATION_FAILED:procurement_documents_and_channel';
 END IF;
END $$;
COMMIT;
