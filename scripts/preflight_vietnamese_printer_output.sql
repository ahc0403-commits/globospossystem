DO $preflight$
DECLARE
  v_target_count integer;
BEGIN
  IF to_regclass('public.restaurants') IS NULL
     OR to_regclass('public.menu_items') IS NULL
     OR to_regclass('public.order_items') IS NULL
     OR to_regclass('public.print_jobs') IS NULL THEN
    RAISE EXCEPTION 'VIETNAMESE_PRINTER_PREFLIGHT_BASE_TABLES_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_items'
      AND column_name = 'name_vi'
  ) THEN
    RAISE EXCEPTION 'VIETNAMESE_PRINTER_PREFLIGHT_NAME_VI_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurants
    WHERE id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
  ) THEN
    RAISE EXCEPTION 'VIETNAMESE_PRINTER_PREFLIGHT_STORE_MISSING';
  END IF;

  SELECT count(*)
  INTO v_target_count
  FROM public.menu_items
  WHERE restaurant_id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
    AND id = ANY (ARRAY[
      '88d94d10-7a42-469c-9d84-b198660e8895'::uuid,
      '9438209e-3d5b-476e-8a1f-81bb2bbfab22'::uuid,
      '40a0e119-f0d5-4e23-bf25-d64aaa214964'::uuid
    ]);

  IF v_target_count <> 3 THEN
    RAISE EXCEPTION 'VIETNAMESE_PRINTER_PREFLIGHT_SENTINEL_ITEMS_MISSING:%',
      v_target_count;
  END IF;

  IF to_regprocedure('public.force_print_job_menu_labels_vi()') IS NOT NULL
     OR EXISTS (
       SELECT 1
       FROM pg_trigger
       WHERE tgname = 'force_print_job_menu_labels_vi'
         AND NOT tgisinternal
     ) THEN
    RAISE EXCEPTION 'VIETNAMESE_PRINTER_PREFLIGHT_PARTIAL_STATE_DETECTED';
  END IF;
END;
$preflight$;
