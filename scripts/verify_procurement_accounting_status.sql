-- Read-only post-apply schema/ACL check; business behavior is verified by the procurement SQL suite.
BEGIN READ ONLY;
DO $$ BEGIN
 IF NOT has_function_privilege('service_role','public.record_procurement_accounting_status(uuid,jsonb)','EXECUTE')
 OR has_function_privilege('authenticated','public.record_procurement_accounting_status(uuid,jsonb)','EXECUTE')
 OR EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.procurement_accounting_status'::regclass AND attname IN ('amount','bank_account','unit_price') AND NOT attisdropped) THEN
  RAISE EXCEPTION 'PROCUREMENT_PRODUCTION_VERIFICATION_FAILED:procurement_accounting_status';
 END IF;
END $$;
COMMIT;
