-- Read-only post-apply verification; transaction behavior is covered by the isolated suite.
BEGIN READ ONLY;
DO $$ BEGIN
 IF NOT has_function_privilege('authenticated','public.procurement_workspace_page(uuid,jsonb,jsonb)','EXECUTE')
 OR has_function_privilege('anon','public.procurement_workspace_page(uuid,jsonb,jsonb)','EXECUTE')
 OR has_function_privilege('authenticated','public.procurement_workspace_page_core(uuid,jsonb,jsonb)','EXECUTE')
 OR has_function_privilege('authenticated','public.procurement_core_command(uuid,text,uuid,integer,text,jsonb,jsonb)','EXECUTE')
 OR position('beverage' IN pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conrelid='public.inventory_purchase_requests'::regclass AND conname='inventory_purchase_requests_purchase_category_check')))=0
 OR to_regclass('public.procurement_requests_store_created') IS NULL
 OR position('request_counts' IN pg_get_functiondef('public.procurement_workspace_page_core(uuid,jsonb,jsonb)'::regprocedure))=0
 OR position('choices=1' IN pg_get_functiondef('public.procurement_core_command(uuid,text,uuid,integer,text,jsonb,jsonb)'::regprocedure))=0 THEN
  RAISE EXCEPTION 'PROCUREMENT_PRODUCTION_VERIFICATION_FAILED:procurement_pr_account';
 END IF;
END $$;
COMMIT;
