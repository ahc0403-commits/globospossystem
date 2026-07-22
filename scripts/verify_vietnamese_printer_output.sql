DO $verify$
DECLARE
  v_definition text;
  v_security_definer boolean;
  v_translation_count integer;
BEGIN
  IF to_regprocedure('public.force_print_job_menu_labels_vi()') IS NULL THEN
    RAISE EXCEPTION 'VIETNAMESE_PRINTER_VERIFY_FUNCTION_MISSING';
  END IF;

  SELECT pg_get_functiondef(p.oid), p.prosecdef
  INTO v_definition, v_security_definer
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.oid = 'public.force_print_job_menu_labels_vi()'::regprocedure;

  IF NOT v_security_definer
     OR v_definition NOT LIKE '%menu.name_vi%'
     OR v_definition NOT LIKE '%ELSE ''Món''%'
     OR v_definition NOT LIKE '%name_vi) !~ ''[가-힣]''%' THEN
    RAISE EXCEPTION 'VIETNAMESE_PRINTER_VERIFY_FUNCTION_CONTRACT_INVALID';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.force_print_job_menu_labels_vi()',
    'EXECUTE'
  ) OR has_function_privilege(
    'authenticated',
    'public.force_print_job_menu_labels_vi()',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'VIETNAMESE_PRINTER_VERIFY_DIRECT_EXECUTE_EXPOSED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'force_print_job_menu_labels_vi'
      AND tgrelid = 'public.print_jobs'::regclass
      AND tgenabled <> 'D'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'VIETNAMESE_PRINTER_VERIFY_TRIGGER_MISSING';
  END IF;

  SELECT count(*)
  INTO v_translation_count
  FROM public.menu_items
  WHERE restaurant_id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
    AND NULLIF(btrim(name_vi), '') IS NOT NULL
    AND name_vi !~ '[가-힣]';

  IF v_translation_count < 99 THEN
    RAISE EXCEPTION 'VIETNAMESE_PRINTER_VERIFY_TRANSLATIONS_INCOMPLETE:%',
      v_translation_count;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.menu_items
    WHERE id = '88d94d10-7a42-469c-9d84-b198660e8895'::uuid
      AND name_vi = 'Kimbap truyền thống'
  ) OR NOT EXISTS (
    SELECT 1 FROM public.menu_items
    WHERE id = '40a0e119-f0d5-4e23-bf25-d64aaa214964'::uuid
      AND name_vi = 'Nước gạo ngọt truyền thống Sikhye'
  ) THEN
    RAISE EXCEPTION 'VIETNAMESE_PRINTER_VERIFY_SENTINEL_TRANSLATIONS_INVALID';
  END IF;
END;
$verify$;
