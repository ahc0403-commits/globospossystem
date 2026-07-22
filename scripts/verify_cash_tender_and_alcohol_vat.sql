\set ON_ERROR_STOP on

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'menu_categories'
      AND column_name = 'system_key'
  ) THEN
    RAISE EXCEPTION 'CASH_TENDER_VAT_VERIFY_SYSTEM_KEY_MISSING';
  END IF;

  IF to_regprocedure('public.enqueue_cash_receipt_print_job(uuid,numeric,boolean)') IS NULL
     OR to_regprocedure('public.protect_system_menu_category()') IS NULL
     OR to_regprocedure('public.ensure_default_alcohol_category()') IS NULL
     OR to_regprocedure('public.sync_menu_item_vat_category()') IS NULL THEN
    RAISE EXCEPTION 'CASH_TENDER_VAT_VERIFY_FUNCTIONS_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.menu_categories mc
    WHERE mc.system_key = 'alcohol'
      AND (mc.name IS DISTINCT FROM '주류'
        OR mc.name_ko IS DISTINCT FROM '주류'
        OR mc.name_vi IS DISTINCT FROM 'Đồ uống có cồn'
        OR mc.name_en IS DISTINCT FROM 'Alcohol'
        OR mc.is_active IS DISTINCT FROM true)
  ) THEN
    RAISE EXCEPTION 'CASH_TENDER_VAT_VERIFY_CANONICAL_CATEGORY_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1 FROM (SELECT DISTINCT restaurant_id FROM public.menu_categories) stores
    WHERE NOT EXISTS (
      SELECT 1 FROM public.menu_categories mc
      WHERE mc.restaurant_id = stores.restaurant_id
        AND mc.system_key = 'alcohol'
    )
  ) THEN
    RAISE EXCEPTION 'CASH_TENDER_VAT_VERIFY_CANONICAL_CATEGORY_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.menu_items mi
    LEFT JOIN public.menu_categories mc ON mc.id = mi.category_id
    WHERE mi.vat_category IS DISTINCT FROM CASE
      WHEN mc.system_key = 'alcohol' THEN 'alcohol' ELSE 'food' END
  ) THEN
    RAISE EXCEPTION 'CASH_TENDER_VAT_VERIFY_ITEM_CLASSIFICATION_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.restaurants r
    WHERE EXISTS (
      SELECT 1 FROM public.menu_categories mc WHERE mc.restaurant_id = r.id
    ) AND r.vat_pricing_mode IS DISTINCT FROM 'exclusive'
  ) THEN
    RAISE EXCEPTION 'CASH_TENDER_VAT_VERIFY_EXCLUSIVE_MODE_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.menu_categories'::regclass
      AND tgname = 'protect_system_menu_category_trigger' AND NOT tgisinternal
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.menu_categories'::regclass
      AND tgname = 'ensure_default_alcohol_category_trigger' AND NOT tgisinternal
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.menu_items'::regclass
      AND tgname = 'sync_menu_item_vat_category_trigger' AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'CASH_TENDER_VAT_VERIFY_TRIGGERS_MISSING';
  END IF;
END;
$$;

SELECT 'PASS: cash tender and protected alcohol VAT verified' AS result;
