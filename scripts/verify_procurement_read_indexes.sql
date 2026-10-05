-- Read-only post-apply schema/ACL check; business behavior is verified by the procurement SQL suite.
BEGIN READ ONLY;
DO $$ BEGIN
 IF (SELECT count(*) FROM pg_index WHERE indexrelid IN ('public.procurement_orders_all_workflows_page'::regclass,'public.procurement_receipt_lines_receipt'::regclass) AND indisvalid AND indisready)<>2
 OR position('WITH page AS MATERIALIZED' IN pg_get_functiondef('public.procurement_orders_batch(uuid[],text,timestamptz,uuid,integer)'::regprocedure))=0 THEN
  RAISE EXCEPTION 'PROCUREMENT_PRODUCTION_VERIFICATION_FAILED:procurement_read_indexes';
 END IF;
END $$;
COMMIT;
