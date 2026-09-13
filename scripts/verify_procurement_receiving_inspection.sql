-- Production verification: catalog and privilege checks only; no business writes.
DO $verify$
BEGIN
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='submit_inventory_receipt_batch'), 'Missing function submit_inventory_receipt_batch';
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='validate_procurement_inspection'), 'Missing function validate_procurement_inspection';
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='verify_inventory_receipt'), 'Missing function verify_inventory_receipt';
 ASSERT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='inventory_receipt_issues' AND c.relrowsecurity), 'Missing RLS table inventory_receipt_issues';
 ASSERT NOT has_table_privilege('anon','public.inventory_receipt_issues','SELECT') AND NOT has_table_privilege('authenticated','public.inventory_receipt_issues','INSERT'), 'Unexpected direct table access inventory_receipt_issues';
 RAISE NOTICE 'PASS: procurement_receiving_inspection production objects and grants';
END $verify$;
