DO $verify$
DECLARE
  v_delete_definition text;
  v_delete_security_definer boolean;
  v_image_definition text;
  v_image_security_definer boolean;
  v_qr_definition text;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_items'
      AND column_name = 'image_url'
      AND data_type = 'text'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_items'
      AND column_name = 'image_storage_path'
      AND data_type = 'text'
  ) THEN
    RAISE EXCEPTION 'MENU_IMAGE_COLUMNS_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM storage.buckets
    WHERE id = 'menu-images'
      AND name = 'menu-images'
      AND public = true
      AND file_size_limit = 5242880
      AND allowed_mime_types @> ARRAY[
        'image/jpeg',
        'image/png',
        'image/webp'
      ]::text[]
  ) THEN
    RAISE EXCEPTION 'MENU_IMAGE_BUCKET_INVALID';
  END IF;

  IF (
    SELECT count(*)
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname IN (
        'storage_menu_images_select_admin',
        'storage_menu_images_insert_admin',
        'storage_menu_images_update_admin',
        'storage_menu_images_delete_admin'
      )
  ) <> 4 THEN
    RAISE EXCEPTION 'MENU_IMAGE_STORAGE_POLICIES_INVALID';
  END IF;

  IF to_regprocedure(
       'public.admin_set_menu_item_image(uuid,text,text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'MENU_IMAGE_FUNCTION_MISSING';
  END IF;

  SELECT proc.prosecdef, pg_get_functiondef(proc.oid)
  INTO v_image_security_definer, v_image_definition
  FROM pg_proc proc
  WHERE proc.oid =
    'public.admin_set_menu_item_image(uuid,text,text)'::regprocedure;

  IF NOT v_image_security_definer
     OR v_image_definition NOT LIKE '%require_admin_actor_for_restaurant%'
     OR v_image_definition NOT LIKE '%MENU_IMAGE_PATH_INVALID%'
     OR v_image_definition NOT LIKE '%MENU_IMAGE_OBJECT_NOT_FOUND%'
     OR v_image_definition NOT LIKE '%storage.objects%' THEN
    RAISE EXCEPTION 'MENU_IMAGE_FUNCTION_DEFINITION_INVALID';
  END IF;

  IF NOT has_function_privilege(
       'authenticated',
       'public.admin_set_menu_item_image(uuid,text,text)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.admin_set_menu_item_image(uuid,text,text)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'public',
       'public.admin_set_menu_item_image(uuid,text,text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'MENU_IMAGE_FUNCTION_PRIVILEGE_INVALID';
  END IF;

  SELECT proc.prosecdef, pg_get_functiondef(proc.oid)
  INTO v_delete_security_definer, v_delete_definition
  FROM pg_proc proc
  WHERE proc.oid =
    'public.admin_delete_menu_category(uuid)'::regprocedure;

  IF NOT v_delete_security_definer
     OR v_delete_definition NOT LIKE '%require_admin_actor_for_restaurant%'
     OR v_delete_definition NOT LIKE '%MENU_CATEGORY_NOT_EMPTY%'
     OR v_delete_definition NOT LIKE '%admin_delete_menu_category%' THEN
    RAISE EXCEPTION 'MENU_CATEGORY_DELETE_DEFINITION_INVALID';
  END IF;

  SELECT pg_get_functiondef(proc.oid)
  INTO v_qr_definition
  FROM pg_proc proc
  WHERE proc.oid = 'public.qr_get_menu(text)'::regprocedure;

  IF v_qr_definition NOT LIKE '%''image_url'', mi.image_url%' THEN
    RAISE EXCEPTION 'QR_MENU_IMAGE_FIELD_MISSING';
  END IF;
END
$verify$;

SELECT 'MENU_CATEGORY_IMAGES_VERIFY_OK';
