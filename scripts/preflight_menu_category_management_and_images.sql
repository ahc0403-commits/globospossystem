DO $preflight$
DECLARE
  v_relation text;
  v_column record;
BEGIN
  FOREACH v_relation IN ARRAY ARRAY[
    'public.menu_categories',
    'public.menu_items',
    'public.audit_logs',
    'public.users',
    'public.table_qr_tokens',
    'public.tables',
    'public.restaurants',
    'storage.buckets',
    'storage.objects'
  ] LOOP
    IF to_regclass(v_relation) IS NULL THEN
      RAISE EXCEPTION 'MENU_IMAGE_BASE_RELATION_MISSING:%', v_relation;
    END IF;
  END LOOP;

  IF to_regprocedure(
       'public.require_admin_actor_for_restaurant(uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'MENU_IMAGE_AUTH_HELPER_MISSING';
  END IF;

  IF to_regprocedure('public.user_accessible_stores(uuid)') IS NULL THEN
    RAISE EXCEPTION 'MENU_IMAGE_STORE_ACCESS_HELPER_MISSING';
  END IF;

  IF to_regprocedure('public.is_super_admin()') IS NULL THEN
    RAISE EXCEPTION 'MENU_IMAGE_SUPER_ADMIN_HELPER_MISSING';
  END IF;

  IF to_regprocedure(
       'public.admin_delete_menu_category(uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_DELETE_FUNCTION_MISSING';
  END IF;

  IF to_regprocedure('public.qr_get_menu(text)') IS NULL THEN
    RAISE EXCEPTION 'QR_MENU_FUNCTION_MISSING';
  END IF;

  FOR v_column IN
    SELECT column_name, data_type
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_items'
      AND column_name IN ('image_url', 'image_storage_path')
  LOOP
    IF v_column.data_type <> 'text' THEN
      RAISE EXCEPTION 'MENU_IMAGE_COLUMN_TYPE_INVALID:%:%',
        v_column.column_name,
        v_column.data_type;
    END IF;
  END LOOP;
END
$preflight$;

SELECT 'MENU_CATEGORY_IMAGES_PREFLIGHT_OK';
