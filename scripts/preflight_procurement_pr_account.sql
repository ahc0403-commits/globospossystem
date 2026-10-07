-- Read-only, fail-closed check against the reviewed production/main predecessor.
BEGIN READ ONLY;
DO $$ BEGIN
 IF encode(extensions.digest(pg_get_functiondef('public.procurement_core_command(uuid,text,uuid,integer,text,jsonb,jsonb)'::regprocedure),'sha256'),'hex')<>'5c6525903b5b5ba303ee197ae0389e89af2e86dc8116ea761e57ebcd78469e65'
 OR encode(extensions.digest(pg_get_functiondef('public.procurement_workspace_page_core(uuid,jsonb,jsonb)'::regprocedure),'sha256'),'hex')<>'1dbd7698d562a7d7d2a585330f7fdeeca691f3c7295a24e8cab5e6bdd1abd866'
 OR encode(extensions.digest(pg_get_functiondef('public.procurement_document_data(uuid,text,uuid,text,jsonb)'::regprocedure),'sha256'),'hex')<>'1d12cd1c88e71599bc1938a0af3b652f3ced81423bc8add1bc8cd4bac7d7c2db' THEN RAISE EXCEPTION 'PROCUREMENT_PR_PREDECESSOR_CHANGED'; END IF;
 IF to_regclass('public.procurement_requests_store_created') IS NOT NULL
 OR position('beverage' IN pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conrelid='public.inventory_purchase_requests'::regclass AND conname='inventory_purchase_requests_purchase_category_check')))>0
 OR NOT has_function_privilege('authenticated','public.procurement_workspace_page(uuid,jsonb,jsonb)','EXECUTE')
 OR has_function_privilege('authenticated','public.procurement_core_command(uuid,text,uuid,integer,text,jsonb,jsonb)','EXECUTE')
 OR position('combined_receiving_inspection' IN pg_get_functiondef('public.submit_inventory_receipt_batch(uuid,uuid,integer,integer,text,jsonb,text,text,text,date,text)'::regprocedure))=0
 THEN RAISE EXCEPTION 'PROCUREMENT_PR_PRECONDITION_FAILED'; END IF;
END $$;
COMMIT;
