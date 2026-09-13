-- Production verification: catalog and privilege checks only; no business writes.
DO $verify$
BEGIN
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='capture_inventory_order_line_terms'), 'Missing function capture_inventory_order_line_terms';
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='get_inventory_actual_purchase_prices'), 'Missing function get_inventory_actual_purchase_prices';
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='verify_inventory_receipt'), 'Missing function verify_inventory_receipt';
 ASSERT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='inventory_purchase_order_lines' AND column_name='cancelled_quantity_base'), 'Missing frozen order terms';
 RAISE NOTICE 'PASS: procurement_receiving_integrity production objects and grants';
END $verify$;
