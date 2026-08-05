-- Menu category lifecycle controls and public menu images.

ALTER TABLE public.menu_items
  ADD COLUMN IF NOT EXISTS image_url text,
  ADD COLUMN IF NOT EXISTS image_storage_path text;

COMMENT ON COLUMN public.menu_items.image_url IS
  'Public URL for the menu item image stored in the menu-images bucket.';
COMMENT ON COLUMN public.menu_items.image_storage_path IS
  'Storage object path used to replace or remove the menu item image.';

INSERT INTO storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
VALUES (
  'menu-images',
  'menu-images',
  true,
  5242880,
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE
SET public = EXCLUDED.public,
    file_size_limit = EXCLUDED.file_size_limit,
    allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS storage_menu_images_select_admin ON storage.objects;
DROP POLICY IF EXISTS storage_menu_images_insert_admin ON storage.objects;
DROP POLICY IF EXISTS storage_menu_images_update_admin ON storage.objects;
DROP POLICY IF EXISTS storage_menu_images_delete_admin ON storage.objects;

CREATE POLICY storage_menu_images_select_admin ON storage.objects
FOR SELECT TO authenticated
USING (
  bucket_id = 'menu-images'
  AND (
    EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) s(store_id)
      WHERE s.store_id::text = (storage.foldername(name))[1]
    )
    OR public.is_super_admin()
  )
);

CREATE POLICY storage_menu_images_insert_admin ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'menu-images'
  AND EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.auth_id = auth.uid()
      AND u.is_active = true
      AND u.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
      AND (
        u.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) s(store_id)
          WHERE s.store_id::text = (storage.foldername(name))[1]
        )
      )
  )
);

CREATE POLICY storage_menu_images_update_admin ON storage.objects
FOR UPDATE TO authenticated
USING (
  bucket_id = 'menu-images'
  AND EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.auth_id = auth.uid()
      AND u.is_active = true
      AND u.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
      AND (
        u.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) s(store_id)
          WHERE s.store_id::text = (storage.foldername(name))[1]
        )
      )
  )
)
WITH CHECK (
  bucket_id = 'menu-images'
  AND EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.auth_id = auth.uid()
      AND u.is_active = true
      AND u.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
      AND (
        u.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) s(store_id)
          WHERE s.store_id::text = (storage.foldername(name))[1]
        )
      )
  )
);

CREATE POLICY storage_menu_images_delete_admin ON storage.objects
FOR DELETE TO authenticated
USING (
  bucket_id = 'menu-images'
  AND EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.auth_id = auth.uid()
      AND u.is_active = true
      AND u.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
      AND (
        u.role = 'super_admin'
        OR EXISTS (
          SELECT 1
          FROM public.user_accessible_stores(auth.uid()) s(store_id)
          WHERE s.store_id::text = (storage.foldername(name))[1]
        )
      )
  )
);

CREATE OR REPLACE FUNCTION public.admin_set_menu_item_image(
  p_item_id uuid,
  p_image_url text DEFAULT NULL,
  p_image_storage_path text DEFAULT NULL
) RETURNS public.menu_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth, storage
AS $$
DECLARE
  v_existing public.menu_items%ROWTYPE;
  v_updated public.menu_items%ROWTYPE;
  v_image_url text := NULLIF(btrim(COALESCE(p_image_url, '')), '');
  v_storage_path text := NULLIF(btrim(COALESCE(p_image_storage_path, '')), '');
BEGIN
  IF p_item_id IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_items
  WHERE id = p_item_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

  IF (v_image_url IS NULL) <> (v_storage_path IS NULL) THEN
    RAISE EXCEPTION 'MENU_IMAGE_METADATA_INCOMPLETE';
  END IF;

  IF v_storage_path IS NOT NULL THEN
    IF v_storage_path NOT LIKE
       v_existing.restaurant_id::text || '/' || v_existing.id::text || '/%' THEN
      RAISE EXCEPTION 'MENU_IMAGE_PATH_INVALID';
    END IF;

    IF v_image_url NOT LIKE '%/storage/v1/object/public/menu-images/%' THEN
      RAISE EXCEPTION 'MENU_IMAGE_URL_INVALID';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM storage.objects o
      WHERE o.bucket_id = 'menu-images'
        AND o.name = v_storage_path
    ) THEN
      RAISE EXCEPTION 'MENU_IMAGE_OBJECT_NOT_FOUND';
    END IF;
  END IF;

  UPDATE public.menu_items
  SET image_url = v_image_url,
      image_storage_path = v_storage_path,
      updated_at = now()
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF v_existing.image_url IS DISTINCT FROM v_updated.image_url
     OR v_existing.image_storage_path IS DISTINCT FROM v_updated.image_storage_path THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_menu_item',
      'menu_items',
      v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.restaurant_id,
        'changed_fields', jsonb_build_array('image_url', 'image_storage_path'),
        'old_values', jsonb_build_object(
          'image_url', v_existing.image_url,
          'image_storage_path', v_existing.image_storage_path
        ),
        'new_values', jsonb_build_object(
          'image_url', v_updated.image_url,
          'image_storage_path', v_updated.image_storage_path
        ),
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_menu_category(
  p_category_id uuid
) RETURNS public.menu_categories
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_existing public.menu_categories%ROWTYPE;
BEGIN
  IF p_category_id IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ID_REQUIRED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_categories
  WHERE id = p_category_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.restaurant_id);

  IF EXISTS (
    SELECT 1
    FROM public.menu_items mi
    WHERE mi.category_id = v_existing.id
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_EMPTY';
  END IF;

  DELETE FROM public.menu_categories
  WHERE id = v_existing.id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_delete_menu_category',
    'menu_categories',
    v_existing.id,
    jsonb_build_object(
      'store_id', v_existing.restaurant_id,
      'deleted_at_utc', now(),
      'old_values', jsonb_build_object(
        'name', v_existing.name,
        'sort_order', v_existing.sort_order,
        'is_active', v_existing.is_active
      )
    )
  );

  RETURN v_existing;
END;
$$;

CREATE OR REPLACE FUNCTION public.qr_get_menu(
  p_token text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_token text := NULLIF(btrim(COALESCE(p_token, '')), '');
  v_table record;
  v_categories jsonb := '[]'::jsonb;
  v_items jsonb := '[]'::jsonb;
BEGIN
  SELECT
    q.restaurant_id,
    q.table_id,
    t.table_number,
    COALESCE(t.floor_label, '1F') AS floor_label,
    r.name AS store_name
  INTO v_table
  FROM public.table_qr_tokens q
  JOIN public.tables t
    ON t.id = q.table_id
   AND t.restaurant_id = q.restaurant_id
  JOIN public.restaurants r
    ON r.id = q.restaurant_id
   AND r.is_active = true
  WHERE q.token = v_token
    AND q.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'QR_TOKEN_INVALID';
  END IF;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', c.id::text,
        'name', c.name,
        'sort_order', c.sort_order
      )
      ORDER BY c.sort_order, c.name, c.id
    ),
    '[]'::jsonb
  )
  INTO v_categories
  FROM public.menu_categories c
  WHERE c.restaurant_id = v_table.restaurant_id
    AND c.is_active = true
    AND EXISTS (
      SELECT 1
      FROM public.menu_items mi
      WHERE mi.restaurant_id = c.restaurant_id
        AND mi.category_id = c.id
        AND mi.is_available = true
        AND mi.is_visible_public = true
    );

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'id', mi.id::text,
        'category_id', mi.category_id::text,
        'name', mi.name,
        'description', mi.description,
        'price', mi.price,
        'image_url', mi.image_url
      )
      ORDER BY COALESCE(mc.sort_order, 0), mi.sort_order, mi.name, mi.id
    ),
    '[]'::jsonb
  )
  INTO v_items
  FROM public.menu_items mi
  LEFT JOIN public.menu_categories mc
    ON mc.id = mi.category_id
  WHERE mi.restaurant_id = v_table.restaurant_id
    AND mi.is_available = true
    AND mi.is_visible_public = true
    AND (mc.id IS NULL OR mc.is_active = true);

  RETURN jsonb_build_object(
    'store_id', v_table.restaurant_id::text,
    'store_name', v_table.store_name,
    'table_id', v_table.table_id::text,
    'table_number', v_table.table_number,
    'floor_label', v_table.floor_label,
    'categories', v_categories,
    'items', v_items
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_menu_item_image(uuid, text, text)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_menu_item_image(uuid, text, text)
TO authenticated;
