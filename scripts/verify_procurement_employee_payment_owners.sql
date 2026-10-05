-- Read-only post-apply schema/ACL check; business behavior is verified by the procurement SQL suite.
BEGIN READ ONLY;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.procurement_channel_payments'::regclass AND attname='office_employee_id' AND NOT attisdropped)
 OR NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid='public.procurement_channel_payments'::regclass AND conname='procurement_payment_parent_kind')
 OR position('PROCUREMENT_EMPLOYEE_MAPPING_REQUIRED' IN pg_get_functiondef('public.procurement_core_command(uuid,text,uuid,integer,text,jsonb,jsonb)'::regprocedure))=0
 OR has_function_privilege('authenticated','public.procurement_core_command(uuid,text,uuid,integer,text,jsonb,jsonb)','EXECUTE') THEN
  RAISE EXCEPTION 'PROCUREMENT_PRODUCTION_VERIFICATION_FAILED:procurement_employee_payment_owners';
 END IF;
END $$;
COMMIT;
