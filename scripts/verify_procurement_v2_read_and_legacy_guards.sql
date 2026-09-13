-- Production verification: catalog and privilege checks only; no business writes.
DO $verify$
BEGIN
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='guard_procurement_v2_line_write'), 'Missing function guard_procurement_v2_line_write';
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='guard_procurement_v2_order_write'), 'Missing function guard_procurement_v2_order_write';
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='procurement_allowed_actions'), 'Missing function procurement_allowed_actions';
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='procurement_workspace'), 'Missing function procurement_workspace';
 ASSERT EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='verify_inventory_receipt'), 'Missing function verify_inventory_receipt';
 ASSERT NOT has_function_privilege('authenticated','public.verify_inventory_receipt_p1(uuid,integer,text,jsonb,text)','EXECUTE'), 'Private receiving verifier exposed';
 RAISE NOTICE 'PASS: procurement_v2_read_and_legacy_guards production objects and grants';
END $verify$;
