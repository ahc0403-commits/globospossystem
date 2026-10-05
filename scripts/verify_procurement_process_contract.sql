-- Read-only post-apply schema/ACL check; business behavior is verified by the procurement SQL suite.
BEGIN READ ONLY;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.inventory_purchase_requests'::regclass AND attname='approval_policy_version' AND attnotnull)
 OR NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.inventory_purchase_request_lines'::regclass AND attname='estimated_unit_price' AND NOT attisdropped)
 OR to_regprocedure('public.procurement_brand_hash(uuid)') IS NULL
 OR to_regprocedure('public.verify_inventory_receipt(uuid,integer,text,jsonb,text)') IS NULL
 OR NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='public.procurement_document_exports'::regclass AND relrowsecurity)
 OR has_table_privilege('authenticated','public.procurement_document_exports','SELECT,INSERT,UPDATE,DELETE')
 OR has_table_privilege('anon','public.procurement_document_exports','SELECT,INSERT,UPDATE,DELETE')
 OR NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='public.procurement_accounting_status'::regclass AND relrowsecurity)
 OR has_table_privilege('authenticated','public.procurement_accounting_status','SELECT,INSERT,UPDATE,DELETE')
 OR has_table_privilege('anon','public.procurement_accounting_status','SELECT,INSERT,UPDATE,DELETE')
 OR NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='public.procurement_channel_payments'::regclass AND relrowsecurity)
 OR has_table_privilege('authenticated','public.procurement_channel_payments','SELECT,INSERT,UPDATE,DELETE')
 OR has_table_privilege('anon','public.procurement_channel_payments','SELECT,INSERT,UPDATE,DELETE') THEN
  RAISE EXCEPTION 'PROCUREMENT_PRODUCTION_VERIFICATION_FAILED:procurement_process_contract';
 END IF;
END $$;
COMMIT;
