-- Read-only post-apply schema/ACL check; business behavior is verified by the procurement SQL suite.
BEGIN READ ONLY;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid='public.inventory_receipt_issues'::regclass AND attname='followup_reference' AND NOT attisdropped)
 OR position('PROCUREMENT_CONFIRMED_FOLLOWUP_REQUIRED' IN pg_get_functiondef('public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb)'::regprocedure))=0
 OR position('PROCUREMENT_POSTED_CREDIT_REQUIRED' IN pg_get_functiondef('public.procurement_command(uuid,text,uuid,integer,text,jsonb,jsonb)'::regprocedure))=0 THEN
  RAISE EXCEPTION 'PROCUREMENT_PRODUCTION_VERIFICATION_FAILED:procurement_nonstock_returns';
 END IF;
END $$;
COMMIT;
