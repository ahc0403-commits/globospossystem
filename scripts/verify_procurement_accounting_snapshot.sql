-- Production verification: catalog and privilege checks only; no business writes.
DO $verify$
BEGIN
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='procurement_order_snapshot'), 'Missing function procurement_order_snapshot';
 RAISE NOTICE 'PASS: procurement_accounting_snapshot production objects and grants';
END $verify$;
