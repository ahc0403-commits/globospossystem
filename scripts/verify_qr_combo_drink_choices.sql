\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_qr_menu_source text;
  v_snapshot_source text;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_items'
      AND column_name = 'combo_drink_choice_count'
  ) THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_CONFIG_SCHEMA_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.menu_categories'::regclass
      AND conname = 'menu_categories_system_key_check'
      AND pg_get_constraintdef(oid) LIKE '%drink%'
  ) THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_CATEGORY_KEY_MISSING';
  END IF;

  IF to_regprocedure('public.identify_drink_menu_category()') IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM pg_trigger
       WHERE tgrelid = 'public.menu_categories'::regclass
         AND tgname = 'identify_drink_menu_category_trigger'
         AND NOT tgisinternal
     ) THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_CATEGORY_IDENTIFICATION_MISSING';
  END IF;

  IF to_regprocedure('public.combo_drink_choice_count(uuid)') IS NULL
     OR to_regprocedure('public.combo_drink_options(uuid)') IS NULL
     OR to_regprocedure('public.admin_set_menu_combo(uuid,boolean,jsonb,integer)') IS NULL
     OR to_regprocedure('public.qr_place_order(text,jsonb,uuid,boolean)') IS NULL THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_FUNCTION_MISSING';
  END IF;

  SELECT prosrc INTO v_qr_menu_source
  FROM pg_proc WHERE oid = 'public.qr_get_menu(text)'::regprocedure;
  SELECT prosrc INTO v_snapshot_source
  FROM pg_proc
  WHERE oid = 'public.snapshot_order_item_combo_components()'::regprocedure;

  IF position('combo_drink_choice_count' IN v_qr_menu_source) = 0
     OR position('combo_drink_options' IN v_qr_menu_source) = 0
     OR position('pos.qr_combo_payload' IN v_snapshot_source) = 0 THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_RUNTIME_WIRING_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE oid = 'public.combo_drink_options(uuid)'::regprocedure
      AND position('menu_categories' IN prosrc) > 0
      AND position('system_key = ''drink''' IN prosrc) > 0
  ) THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_CATEGORY_OPTIONS_NOT_WIRED';
  END IF;

  IF NOT has_function_privilege(
       'anon', 'public.qr_place_order(text,jsonb,uuid,boolean)', 'EXECUTE'
     ) OR has_function_privilege(
       'anon', 'public.combo_drink_options(uuid)', 'EXECUTE'
     ) OR has_function_privilege(
       'authenticated', 'public.combo_drink_choice_count(uuid)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_FUNCTION_PRIVILEGE_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.menu_items combo
    WHERE combo.is_combo = true
      AND combo.is_archived = false
      AND public.combo_drink_choice_count(combo.id) > 0
      AND jsonb_array_length(public.combo_drink_options(combo.id)) = 0
  ) THEN
    RAISE EXCEPTION 'QR_COMBO_DRINK_OPTIONS_EMPTY';
  END IF;
END
$verify$;

SELECT 'QR_COMBO_DRINK_VERIFY_OK' AS result;
