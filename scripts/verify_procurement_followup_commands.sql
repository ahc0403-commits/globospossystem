-- Production verification: catalog and privilege checks only; no business writes.
DO $verify$
BEGIN
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='procurement_command'), 'Missing function procurement_command';
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='procurement_workspace'), 'Missing function procurement_workspace';
 ASSERT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='inventory_supplier_returns' AND c.relrowsecurity), 'Missing RLS table inventory_supplier_returns';
 ASSERT NOT has_table_privilege('anon','public.inventory_supplier_returns','SELECT') AND NOT has_table_privilege('authenticated','public.inventory_supplier_returns','INSERT'), 'Unexpected direct table access inventory_supplier_returns';
 RAISE NOTICE 'PASS: procurement_followup_commands production objects and grants';
END $verify$;
