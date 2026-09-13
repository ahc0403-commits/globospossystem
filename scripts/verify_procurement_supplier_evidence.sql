-- Production verification: catalog and privilege checks only; no business writes.
DO $verify$
BEGIN
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='procurement_supplier_evidence'), 'Missing function procurement_supplier_evidence';
 RAISE NOTICE 'PASS: procurement_supplier_evidence production objects and grants';
END $verify$;
