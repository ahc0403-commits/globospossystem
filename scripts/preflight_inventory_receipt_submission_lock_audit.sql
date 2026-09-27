\set ON_ERROR_STOP on
BEGIN READ ONLY;
DO $preflight$
BEGIN
  IF to_regclass('public.inventory_receipts') IS NULL
    OR to_regclass('public.inventory_receipt_lines') IS NULL
    OR to_regprocedure('public.can_verify_inventory_receipt(uuid)') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_SUBMISSION_PREREQUISITE_MISSING';
  END IF;
  IF to_regclass('public.inventory_receipt_change_history') IS NOT NULL
    OR EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgname IN ('inventory_receipt_header_change_guard',
                       'inventory_receipt_line_change_guard') AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'INVENTORY_RECEIPT_SUBMISSION_GUARD_ALREADY_PRESENT';
  END IF;
END $preflight$;
ROLLBACK;
