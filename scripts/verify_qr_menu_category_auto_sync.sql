DO $verify$
DECLARE
  v_qr_definition text;
  v_create_definition text;
BEGIN
  SELECT pg_get_functiondef('public.qr_get_menu(text)'::regprocedure)
  INTO v_qr_definition;
  SELECT pg_get_functiondef(
    'public.admin_create_menu_item_i18n_paperless(uuid,uuid,text,text,text,text,numeric,integer,boolean)'::regprocedure
  ) INTO v_create_definition;

  IF v_qr_definition !~
       'category\.restaurant_id = v_table\.restaurant_id[[:space:]]+AND category\.is_active = true;'
     OR v_qr_definition ~
       'category\.is_active = true[[:space:]]+AND EXISTS'
     OR position('menu.is_archived = false' IN v_qr_definition) = 0 THEN
    RAISE EXCEPTION 'QR_MENU_ACTIVE_CATEGORY_SYNC_INVALID';
  END IF;

  IF position(
       'COALESCE(p_is_available, true), true, COALESCE(p_sort_order, 0)'
       IN v_create_definition
     ) = 0 THEN
    RAISE EXCEPTION 'QR_MENU_CREATE_DEFAULT_VISIBILITY_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.menu_items menu
    JOIN public.menu_categories category
      ON category.id = menu.category_id
     AND category.restaurant_id = menu.restaurant_id
    WHERE category.is_active = true
      AND (
        lower(btrim(category.name)) = lower('메뉴 TOP7')
        OR lower(btrim(COALESCE(category.name_ko, ''))) = lower('메뉴 TOP7')
      )
      AND menu.is_archived = false
      AND menu.is_visible_public = false
  ) THEN
    RAISE EXCEPTION 'QR_MENU_TOP7_BACKFILL_INCOMPLETE';
  END IF;
END;
$verify$;

DO $verify$
BEGIN
  IF has_function_privilege(
       'public',
       'public.qr_get_menu(text)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'anon',
       'public.qr_get_menu(text)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.qr_get_menu(text)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.admin_create_menu_item_i18n_paperless(uuid,uuid,text,text,text,text,numeric,integer,boolean)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.admin_create_menu_item_i18n_paperless(uuid,uuid,text,text,text,text,numeric,integer,boolean)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'QR_MENU_FUNCTION_PRIVILEGE_INVALID';
  END IF;
END;
$verify$;
