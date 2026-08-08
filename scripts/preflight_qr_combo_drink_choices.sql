\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.menu_items') IS NULL
     OR to_regclass('public.menu_categories') IS NULL
     OR to_regclass('public.menu_combo_components') IS NULL
     OR to_regclass('public.order_items') IS NULL
     OR to_regclass('public.qr_order_batches') IS NULL THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_REQUIRED_RELATION_MISSING';
  END IF;

  IF to_regprocedure('public.qr_get_menu(text)') IS NULL
     OR to_regprocedure('public.qr_place_order(text,jsonb,uuid)') IS NULL
     OR to_regprocedure('public.snapshot_order_item_combo_components()') IS NULL THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_REQUIRED_FUNCTION_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'menu_items'
      AND column_name = 'is_combo'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'order_items'
      AND column_name = 'combo_components'
  ) THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_REQUIRED_COLUMN_MISSING';
  END IF;
END
$preflight$;

SELECT 'QR_COMBO_DRINK_PREFLIGHT_OK' AS result;
