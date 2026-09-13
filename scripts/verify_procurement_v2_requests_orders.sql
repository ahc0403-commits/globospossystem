-- Production verification: catalog and privilege checks only; no business writes.
DO $verify$
BEGIN
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='procurement_actor'), 'Missing function procurement_actor';
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='procurement_command'), 'Missing function procurement_command';
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='procurement_request_hash'), 'Missing function procurement_request_hash';
 ASSERT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='inventory_purchase_request_lines' AND c.relrowsecurity), 'Missing RLS table inventory_purchase_request_lines';
 ASSERT NOT has_table_privilege('anon','public.inventory_purchase_request_lines','SELECT') AND NOT has_table_privilege('authenticated','public.inventory_purchase_request_lines','INSERT'), 'Unexpected direct table access inventory_purchase_request_lines';
 ASSERT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='inventory_purchase_requests' AND c.relrowsecurity), 'Missing RLS table inventory_purchase_requests';
 ASSERT NOT has_table_privilege('anon','public.inventory_purchase_requests','SELECT') AND NOT has_table_privilege('authenticated','public.inventory_purchase_requests','INSERT'), 'Unexpected direct table access inventory_purchase_requests';
 ASSERT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='procurement_allocations' AND c.relrowsecurity), 'Missing RLS table procurement_allocations';
 ASSERT NOT has_table_privilege('anon','public.procurement_allocations','SELECT') AND NOT has_table_privilege('authenticated','public.procurement_allocations','INSERT'), 'Unexpected direct table access procurement_allocations';
 ASSERT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='procurement_command_results' AND c.relrowsecurity), 'Missing RLS table procurement_command_results';
 ASSERT NOT has_table_privilege('anon','public.procurement_command_results','SELECT') AND NOT has_table_privilege('authenticated','public.procurement_command_results','INSERT'), 'Unexpected direct table access procurement_command_results';
 ASSERT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='procurement_events' AND c.relrowsecurity), 'Missing RLS table procurement_events';
 ASSERT NOT has_table_privilege('anon','public.procurement_events','SELECT') AND NOT has_table_privilege('authenticated','public.procurement_events','INSERT'), 'Unexpected direct table access procurement_events';
 ASSERT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='procurement_quote_lines' AND c.relrowsecurity), 'Missing RLS table procurement_quote_lines';
 ASSERT NOT has_table_privilege('anon','public.procurement_quote_lines','SELECT') AND NOT has_table_privilege('authenticated','public.procurement_quote_lines','INSERT'), 'Unexpected direct table access procurement_quote_lines';
 ASSERT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='procurement_quotes' AND c.relrowsecurity), 'Missing RLS table procurement_quotes';
 ASSERT NOT has_table_privilege('anon','public.procurement_quotes','SELECT') AND NOT has_table_privilege('authenticated','public.procurement_quotes','INSERT'), 'Unexpected direct table access procurement_quotes';
 ASSERT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relname='procurement_store_policies' AND c.relrowsecurity), 'Missing RLS table procurement_store_policies';
 ASSERT NOT has_table_privilege('anon','public.procurement_store_policies','SELECT') AND NOT has_table_privilege('authenticated','public.procurement_store_policies','INSERT'), 'Unexpected direct table access procurement_store_policies';
 RAISE NOTICE 'PASS: procurement_v2_requests_orders production objects and grants';
END $verify$;
