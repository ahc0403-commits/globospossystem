-- Read-only post-apply schema/ACL check; business behavior is verified by the procurement SQL suite.
BEGIN READ ONLY;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.inventory_purchase_orders'::regclass AND tgname='procurement_legacy_creation_guard' AND tgenabled<>'D')
 OR NOT has_function_privilege('authenticated','public.procurement_receipt_evidence(uuid,uuid,jsonb)','EXECUTE')
 OR has_function_privilege('anon','public.procurement_issue_context(uuid,uuid,jsonb)','EXECUTE') THEN
  RAISE EXCEPTION 'PROCUREMENT_PRODUCTION_VERIFICATION_FAILED:procurement_legacy_entry_and_evidence';
 END IF;
END $$;
COMMIT;
