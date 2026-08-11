\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.restaurants') IS NULL
     OR to_regclass('public.restaurant_settings') IS NULL
     OR to_regclass('public.orders') IS NULL
     OR to_regclass('public.order_items') IS NULL
     OR to_regclass('public.print_jobs') IS NULL
     OR to_regclass('public.customer_payment_displays') IS NULL
     OR to_regclass('public.emergency_fulfillment_sessions') IS NULL
     OR to_regclass('public.emergency_fulfillment_items') IS NULL THEN
    RAISE EXCEPTION 'PAPERLESS_RECEIPT_PREFLIGHT_DEPENDENCY_MISSING';
  END IF;

  IF to_regprocedure('public.process_payment(uuid,uuid,numeric,text)') IS NULL
     AND NOT EXISTS (
       SELECT 1 FROM pg_proc procedure
       JOIN pg_namespace namespace ON namespace.oid = procedure.pronamespace
       WHERE namespace.nspname = 'public'
         AND procedure.proname = 'process_payment'
     ) THEN
    RAISE EXCEPTION 'PAPERLESS_RECEIPT_PAYMENT_ANCHOR_MISSING';
  END IF;

  IF to_regprocedure('public.emergency_complete_order_stage(uuid,uuid)') IS NULL
     OR to_regprocedure('public.enqueue_receipt_print_job(uuid,boolean)') IS NULL THEN
    RAISE EXCEPTION 'PAPERLESS_RECEIPT_COMPATIBILITY_RPC_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name IN ('orders', 'order_items')
      AND column_name = 'fulfillment_mode_snapshot'
  ) OR to_regclass('public.digital_receipts') IS NOT NULL THEN
    RAISE EXCEPTION 'PAPERLESS_RECEIPT_PARTIAL_OR_ALREADY_APPLIED';
  END IF;

  IF to_regclass('public.digital_receipt_links') IS NOT NULL
     OR to_regclass('public.digital_receipt_access_limits') IS NOT NULL THEN
    RAISE EXCEPTION 'PAPERLESS_RECEIPT_SECURITY_PARTIAL_OR_ALREADY_APPLIED';
  END IF;
END;
$preflight$;

SELECT 'PAPERLESS_RECEIPT_PREFLIGHT_OK' AS result;
