-- Read-only post-apply schema/ACL check; business behavior is verified by the procurement SQL suite.
BEGIN READ ONLY;
DO $$ BEGIN
 IF (SELECT count(*) FROM pg_policy WHERE polrelid='storage.objects'::regclass AND polname IN ('inventory_purchase_document_objects_read','procurement_pr_objects_insert','procurement_pr_objects_update'))<>3
 OR NOT has_function_privilege('authenticated','public.can_write_procurement_pr_document(text)','EXECUTE')
 OR has_function_privilege('anon','public.can_read_procurement_document(text)','EXECUTE') THEN
  RAISE EXCEPTION 'PROCUREMENT_PRODUCTION_VERIFICATION_FAILED:procurement_document_storage_scope';
 END IF;
END $$;
COMMIT;
