\set ON_ERROR_STOP on
BEGIN READ ONLY;
DO $verify$
BEGIN
  IF to_regclass('public.inventory_receipt_change_history') IS NULL
    OR to_regprocedure('public.guard_inventory_receipt_header_change()') IS NULL
    OR to_regprocedure('public.guard_inventory_receipt_line_change()') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_SUBMISSION_GUARD_MISSING';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid = 'public.inventory_receipts'::regclass
        AND tgname = 'inventory_receipt_header_change_guard' AND NOT tgisinternal)
    OR NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid = 'public.inventory_receipt_lines'::regclass
        AND tgname = 'inventory_receipt_line_change_guard' AND NOT tgisinternal)
    OR NOT EXISTS (SELECT 1 FROM pg_policies
      WHERE schemaname = 'public'
        AND tablename = 'inventory_receipt_change_history'
        AND policyname = 'inventory_receipt_change_history_accounting_read') THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_SUBMISSION_TRIGGER_OR_POLICY_MISSING';
  END IF;
  IF has_function_privilege('authenticated',
      'public.guard_inventory_receipt_header_change()', 'EXECUTE')
    OR has_function_privilege('authenticated',
      'public.guard_inventory_receipt_line_change()', 'EXECUTE') THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_SUBMISSION_GUARD_DIRECT_ACCESS';
  END IF;
END $verify$;
SELECT 'inventory receipt submission guard verified' AS result;
ROLLBACK;
