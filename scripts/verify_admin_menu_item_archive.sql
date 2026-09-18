\set ON_ERROR_STOP on

DO $$
DECLARE
  v_archive_definition text;
  v_category_definition text;
BEGIN
  IF to_regprocedure('public.admin_archive_menu_item(uuid)') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_MENU_ARCHIVE_FUNCTION_MISSING';
  END IF;

  v_archive_definition := pg_get_functiondef(
    'public.admin_archive_menu_item(uuid)'::regprocedure
  );
  v_category_definition := pg_get_functiondef(
    'public.admin_delete_menu_category(uuid)'::regprocedure
  );

  IF position('is_archived = true' in v_archive_definition) = 0
     OR position('is_available = false' in v_archive_definition) = 0
     OR position('is_visible_public = false' in v_archive_definition) = 0
     OR position('MENU_COMBO_COMPONENT_IN_USE' in v_archive_definition) = 0
     OR position('delete_mode' in v_archive_definition) = 0
     OR position('DELETE FROM public.menu_items' in v_archive_definition) > 0
     OR position('item.is_archived = false' in v_category_definition) = 0 THEN
    RAISE EXCEPTION 'ADMIN_MENU_ARCHIVE_DEFINITION_INVALID';
  END IF;

  IF to_regclass(
    'public.menu_combo_components_restaurant_component_idx'
  ) IS NULL THEN
    RAISE EXCEPTION 'ADMIN_MENU_ARCHIVE_COMPONENT_INDEX_MISSING';
  END IF;

  IF NOT has_function_privilege(
    'authenticated', 'public.admin_archive_menu_item(uuid)', 'EXECUTE'
  ) OR has_function_privilege(
    'anon', 'public.admin_archive_menu_item(uuid)', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'ADMIN_MENU_ARCHIVE_PRIVILEGE_INVALID';
  END IF;
END;
$$;

SELECT 'ADMIN_MENU_ITEM_ARCHIVE_VERIFY_OK' AS result;
