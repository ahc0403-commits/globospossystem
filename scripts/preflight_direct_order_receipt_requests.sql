-- Presentation-only migration; no operational rows are changed.
BEGIN;
DO $preflight$
BEGIN
  IF to_regprocedure('public.direct_order_receipt_content(uuid,uuid,jsonb)') IS NOT NULL
    OR to_regprocedure('public.direct_order_receipt_packing_context(uuid,uuid)') IS NULL
    OR to_regprocedure('public.direct_order_fulfillment_context(uuid)') IS NULL
    OR to_regprocedure('public.force_print_job_menu_labels_vi()') IS NULL
    OR to_regprocedure('public.digital_receipt_force_vietnamese_items()') IS NULL
    OR NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid='public.print_jobs'::regclass
        AND tgname='zz_direct_order_enrich_print_fulfillment'
        AND tgfoid='public.direct_order_enrich_print_fulfillment()'::regprocedure
        AND tgtype=7 AND tgenabled='O')
    OR NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid='public.digital_receipts'::regclass
        AND tgname='zz_direct_order_enrich_digital_receipt_packing'
        AND tgfoid='public.direct_order_enrich_digital_receipt_packing()'::regprocedure
        AND tgtype=7 AND tgenabled='O')
    OR EXISTS (SELECT order_id FROM public.direct_order_financials
      GROUP BY order_id HAVING count(*)>1) THEN
    RAISE EXCEPTION 'RECEIPT_REQUESTS_PREFLIGHT_FAILED';
  END IF;
END;
$preflight$;
ROLLBACK;
SELECT 'RECEIPT_REQUESTS_PREFLIGHT=PASS';
