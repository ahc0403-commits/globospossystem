-- Production verification: catalog and privilege checks only; no business writes.
DO $verify$
BEGIN
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='procurement_repair_legacy_terms'), 'Missing function procurement_repair_legacy_terms';
 ASSERT NOT has_function_privilege('authenticated','public.procurement_repair_legacy_terms(uuid,uuid,integer,text,jsonb,jsonb)','EXECUTE'), 'Private historical repair exposed';
 RAISE NOTICE 'PASS: procurement_legacy_terms_review production objects and grants';
END $verify$;
