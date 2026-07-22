\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regclass('public.menu_categories') IS NULL
     OR to_regclass('public.menu_items') IS NULL
     OR to_regclass('public.print_jobs') IS NULL THEN
    RAISE EXCEPTION 'CASH_TENDER_VAT_PREFLIGHT_TABLES_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'menu_items'
      AND column_name = 'vat_category'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurants'
      AND column_name = 'vat_pricing_mode'
  ) OR EXISTS (
    SELECT 1
    FROM (VALUES ('name_ko'), ('name_vi'), ('name_en')) required(column_name)
    WHERE NOT EXISTS (
      SELECT 1 FROM information_schema.columns c
      WHERE c.table_schema = 'public'
        AND c.table_name = 'menu_categories'
        AND c.column_name = required.column_name
    )
  ) THEN
    RAISE EXCEPTION 'CASH_TENDER_VAT_PREFLIGHT_COLUMNS_MISSING';
  END IF;

  IF to_regprocedure('public.enqueue_receipt_print_job(uuid,boolean)') IS NULL
     OR to_regprocedure('public.enrich_cashier_receipt_payload()') IS NULL THEN
    RAISE EXCEPTION 'CASH_TENDER_VAT_PREFLIGHT_RECEIPT_FUNCTIONS_MISSING';
  END IF;
END;
$$;

SELECT 'PASS: cash tender and alcohol VAT preflight' AS result;
