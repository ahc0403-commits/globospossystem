-- Atomic Excel menu import for the authenticated store admin.

CREATE OR REPLACE FUNCTION public.admin_import_menu_items(
  p_store_id UUID,
  p_rows JSONB
) RETURNS JSONB AS $$
DECLARE
  v_entry RECORD;
  v_row JSONB;
  v_source_row INT;
  v_category_name TEXT;
  v_category_sort_order INT;
  v_category_id UUID;
  v_category_count INT;
  v_menu_name TEXT;
  v_description TEXT;
  v_price NUMERIC(12, 2);
  v_is_available BOOLEAN;
  v_is_visible_public BOOLEAN;
  v_sort_order INT;
  v_created_category public.menu_categories%ROWTYPE;
  v_created_item public.menu_items%ROWTYPE;
  v_created_category_count INT := 0;
  v_imported_item_count INT := 0;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'MENU_IMPORT_STORE_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'MENU_IMPORT_ROWS_INVALID';
  END IF;
  IF jsonb_array_length(p_rows) = 0 THEN
    RAISE EXCEPTION 'MENU_IMPORT_ROWS_EMPTY';
  END IF;
  IF jsonb_array_length(p_rows) > 500 THEN
    RAISE EXCEPTION 'MENU_IMPORT_TOO_MANY_ROWS';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (
      SELECT
        lower(btrim(value ->> 'category_name')) AS category_key,
        lower(btrim(value ->> 'name')) AS menu_key,
        count(*) AS duplicate_count
      FROM jsonb_array_elements(p_rows)
      GROUP BY 1, 2
    ) duplicates
    WHERE duplicates.category_key <> ''
      AND duplicates.menu_key <> ''
      AND duplicates.duplicate_count > 1
  ) THEN
    RAISE EXCEPTION 'MENU_IMPORT_DUPLICATE_ROWS';
  END IF;

  FOR v_entry IN
    SELECT value, ordinality
    FROM jsonb_array_elements(p_rows) WITH ORDINALITY
  LOOP
    v_row := v_entry.value;
    v_source_row := COALESCE(
      CASE
        WHEN jsonb_typeof(v_row -> 'source_row') = 'number'
          THEN (v_row ->> 'source_row')::INT
        ELSE NULL
      END,
      v_entry.ordinality::INT + 1
    );

    IF jsonb_typeof(v_row) <> 'object' THEN
      RAISE EXCEPTION 'MENU_IMPORT_ROW_INVALID:%', v_source_row;
    END IF;

    v_category_name := NULLIF(btrim(COALESCE(v_row ->> 'category_name', '')), '');
    v_menu_name := NULLIF(btrim(COALESCE(v_row ->> 'name', '')), '');
    v_description := NULLIF(btrim(COALESCE(v_row ->> 'description', '')), '');

    IF v_category_name IS NULL OR char_length(v_category_name) > 200 THEN
      RAISE EXCEPTION 'MENU_IMPORT_CATEGORY_INVALID:%', v_source_row;
    END IF;
    IF v_menu_name IS NULL OR char_length(v_menu_name) > 200 THEN
      RAISE EXCEPTION 'MENU_IMPORT_NAME_INVALID:%', v_source_row;
    END IF;
    IF v_description IS NOT NULL AND char_length(v_description) > 1000 THEN
      RAISE EXCEPTION 'MENU_IMPORT_DESCRIPTION_INVALID:%', v_source_row;
    END IF;

    IF jsonb_typeof(v_row -> 'price') <> 'number' THEN
      RAISE EXCEPTION 'MENU_IMPORT_PRICE_INVALID:%', v_source_row;
    END IF;
    v_price := (v_row ->> 'price')::NUMERIC(12, 2);
    IF v_price <= 0 THEN
      RAISE EXCEPTION 'MENU_IMPORT_PRICE_INVALID:%', v_source_row;
    END IF;

    IF jsonb_typeof(v_row -> 'category_sort_order') <> 'number'
       OR jsonb_typeof(v_row -> 'sort_order') <> 'number' THEN
      RAISE EXCEPTION 'MENU_IMPORT_SORT_INVALID:%', v_source_row;
    END IF;
    v_category_sort_order := (v_row ->> 'category_sort_order')::INT;
    v_sort_order := (v_row ->> 'sort_order')::INT;
    IF v_category_sort_order < 0 OR v_sort_order < 0 THEN
      RAISE EXCEPTION 'MENU_IMPORT_SORT_INVALID:%', v_source_row;
    END IF;

    IF jsonb_typeof(v_row -> 'is_available') <> 'boolean'
       OR jsonb_typeof(v_row -> 'is_visible_public') <> 'boolean' THEN
      RAISE EXCEPTION 'MENU_IMPORT_BOOLEAN_INVALID:%', v_source_row;
    END IF;
    v_is_available := (v_row ->> 'is_available')::BOOLEAN;
    v_is_visible_public := (v_row ->> 'is_visible_public')::BOOLEAN;

    SELECT count(*)
    INTO v_category_count
    FROM public.menu_categories
    WHERE restaurant_id = p_store_id
      AND lower(btrim(name)) = lower(v_category_name);

    IF v_category_count > 1 THEN
      RAISE EXCEPTION 'MENU_IMPORT_CATEGORY_AMBIGUOUS:%', v_source_row;
    END IF;

    IF v_category_count = 0 THEN
      INSERT INTO public.menu_categories (
        restaurant_id,
        name,
        sort_order,
        is_active,
        created_at
      ) VALUES (
        p_store_id,
        v_category_name,
        v_category_sort_order,
        TRUE,
        now()
      )
      RETURNING * INTO v_created_category;

      v_category_id := v_created_category.id;
      v_created_category_count := v_created_category_count + 1;

      INSERT INTO public.audit_logs (
        actor_id,
        action,
        entity_type,
        entity_id,
        details
      ) VALUES (
        auth.uid(),
        'admin_create_menu_category',
        'menu_categories',
        v_created_category.id,
        jsonb_build_object(
          'restaurant_id', p_store_id,
          'source', 'excel_import',
          'source_row', v_source_row,
          'created_at_utc', now(),
          'new_values', jsonb_build_object(
            'name', v_created_category.name,
            'sort_order', v_created_category.sort_order,
            'is_active', v_created_category.is_active
          )
        )
      );
    ELSE
      SELECT id
      INTO v_category_id
      FROM public.menu_categories
      WHERE restaurant_id = p_store_id
        AND lower(btrim(name)) = lower(v_category_name)
      LIMIT 1;

      IF EXISTS (
        SELECT 1
        FROM public.menu_categories
        WHERE id = v_category_id
          AND is_active = FALSE
      ) THEN
        RAISE EXCEPTION 'MENU_IMPORT_CATEGORY_INACTIVE:%', v_source_row;
      END IF;
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.menu_items
      WHERE restaurant_id = p_store_id
        AND category_id = v_category_id
        AND lower(btrim(name)) = lower(v_menu_name)
    ) THEN
      RAISE EXCEPTION 'MENU_IMPORT_ITEM_EXISTS:%:%', v_source_row, v_menu_name;
    END IF;

    INSERT INTO public.menu_items (
      restaurant_id,
      category_id,
      name,
      description,
      price,
      is_available,
      is_visible_public,
      sort_order,
      created_at,
      updated_at
    ) VALUES (
      p_store_id,
      v_category_id,
      v_menu_name,
      v_description,
      v_price,
      v_is_available,
      v_is_visible_public,
      v_sort_order,
      now(),
      now()
    )
    RETURNING * INTO v_created_item;

    v_imported_item_count := v_imported_item_count + 1;

    INSERT INTO public.audit_logs (
      actor_id,
      action,
      entity_type,
      entity_id,
      details
    ) VALUES (
      auth.uid(),
      'admin_create_menu_item',
      'menu_items',
      v_created_item.id,
      jsonb_build_object(
        'restaurant_id', p_store_id,
        'source', 'excel_import',
        'source_row', v_source_row,
        'created_at_utc', now(),
        'new_values', jsonb_build_object(
          'category_id', v_created_item.category_id,
          'name', v_created_item.name,
          'description', v_created_item.description,
          'price', v_created_item.price,
          'is_available', v_created_item.is_available,
          'is_visible_public', v_created_item.is_visible_public,
          'sort_order', v_created_item.sort_order
        )
      )
    );
  END LOOP;

  RETURN jsonb_build_object(
    'created_category_count', v_created_category_count,
    'imported_item_count', v_imported_item_count
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

REVOKE ALL ON FUNCTION public.admin_import_menu_items(UUID, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_import_menu_items(UUID, JSONB) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_import_menu_items(UUID, JSONB) TO authenticated;
