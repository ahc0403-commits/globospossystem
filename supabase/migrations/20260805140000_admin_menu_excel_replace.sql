-- Replace a store's complete menu catalog from Excel while preserving photos
-- (and stable menu IDs) for rows that still represent the same menu.

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
  v_menu_name TEXT;
  v_description TEXT;
  v_price NUMERIC(12, 2);
  v_is_available BOOLEAN;
  v_is_visible_public BOOLEAN;
  v_sort_order INT;
  v_old_category_count INT;
  v_old_item_count INT;
  v_category_count INT;
  v_item_count INT;
  v_created_category_count INT;
  v_created_item_count INT;
  v_updated_item_count INT;
  v_deleted_category_count INT;
  v_deleted_item_count INT;
  v_preserved_image_count INT;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'MENU_IMPORT_STORE_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);
  PERFORM pg_advisory_xact_lock(hashtextextended(p_store_id::text, 0));

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

  DROP TABLE IF EXISTS pg_temp.menu_import_stage_items;
  DROP TABLE IF EXISTS pg_temp.menu_import_stage_categories;
  CREATE TEMP TABLE menu_import_stage_categories (
    category_key TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    sort_order INT NOT NULL,
    category_id UUID
  ) ON COMMIT DROP;
  CREATE TEMP TABLE menu_import_stage_items (
    source_row INT NOT NULL,
    category_key TEXT NOT NULL,
    menu_key TEXT NOT NULL,
    name TEXT NOT NULL,
    description TEXT,
    price NUMERIC(12, 2) NOT NULL,
    is_available BOOLEAN NOT NULL,
    is_visible_public BOOLEAN NOT NULL,
    sort_order INT NOT NULL,
    matched_item_id UUID,
    PRIMARY KEY (category_key, menu_key)
  ) ON COMMIT DROP;
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

    INSERT INTO pg_temp.menu_import_stage_categories (
      category_key,
      name,
      sort_order
    ) VALUES (
      lower(v_category_name),
      v_category_name,
      v_category_sort_order
    )
    ON CONFLICT (category_key) DO UPDATE
    SET name = EXCLUDED.name
    WHERE menu_import_stage_categories.sort_order = EXCLUDED.sort_order;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'MENU_IMPORT_CATEGORY_SORT_CONFLICT:%', v_source_row;
    END IF;

    INSERT INTO pg_temp.menu_import_stage_items (
      source_row,
      category_key,
      menu_key,
      name,
      description,
      price,
      is_available,
      is_visible_public,
      sort_order
    ) VALUES (
      v_source_row,
      lower(v_category_name),
      lower(v_menu_name),
      v_menu_name,
      v_description,
      v_price,
      v_is_available,
      v_is_visible_public,
      v_sort_order
    );
  END LOOP;

  -- Serialize catalog replacement for the store and protect image-bearing rows.
  PERFORM id
  FROM public.menu_categories
  WHERE restaurant_id = p_store_id
  FOR UPDATE;
  PERFORM id
  FROM public.menu_items
  WHERE restaurant_id = p_store_id
  FOR UPDATE;

  SELECT count(*) INTO v_old_category_count
  FROM public.menu_categories
  WHERE restaurant_id = p_store_id;
  SELECT count(*) INTO v_old_item_count
  FROM public.menu_items
  WHERE restaurant_id = p_store_id;

  IF EXISTS (
    SELECT 1
    FROM public.menu_categories c
    JOIN pg_temp.menu_import_stage_categories s
      ON lower(btrim(c.name)) = s.category_key
    WHERE c.restaurant_id = p_store_id
    GROUP BY s.category_key
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'MENU_IMPORT_CATEGORY_AMBIGUOUS';
  END IF;

  UPDATE pg_temp.menu_import_stage_categories s
  SET category_id = c.id
  FROM public.menu_categories c
  WHERE c.restaurant_id = p_store_id
    AND lower(btrim(c.name)) = s.category_key;

  UPDATE public.menu_categories c
  SET name = s.name,
      sort_order = s.sort_order,
      is_active = TRUE
  FROM pg_temp.menu_import_stage_categories s
  WHERE c.id = s.category_id;

  INSERT INTO public.menu_categories (
    restaurant_id,
    name,
    sort_order,
    is_active,
    created_at
  )
  SELECT p_store_id, s.name, s.sort_order, TRUE, now()
  FROM pg_temp.menu_import_stage_categories s
  WHERE s.category_id IS NULL;
  GET DIAGNOSTICS v_created_category_count = ROW_COUNT;

  UPDATE pg_temp.menu_import_stage_categories s
  SET category_id = c.id
  FROM public.menu_categories c
  WHERE c.restaurant_id = p_store_id
    AND lower(btrim(c.name)) = s.category_key
    AND s.category_id IS NULL;

  -- First preserve exact category/name matches.
  IF EXISTS (
    SELECT 1
    FROM public.menu_items mi
    JOIN public.menu_categories c ON c.id = mi.category_id
    JOIN pg_temp.menu_import_stage_items s
      ON s.category_key = lower(btrim(c.name))
     AND s.menu_key = lower(btrim(mi.name))
    WHERE mi.restaurant_id = p_store_id
    GROUP BY s.category_key, s.menu_key
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'MENU_IMPORT_ITEM_AMBIGUOUS';
  END IF;

  UPDATE pg_temp.menu_import_stage_items s
  SET matched_item_id = mi.id
  FROM public.menu_items mi
  JOIN public.menu_categories c ON c.id = mi.category_id
  WHERE mi.restaurant_id = p_store_id
    AND lower(btrim(c.name)) = s.category_key
    AND lower(btrim(mi.name)) = s.menu_key;

  -- If a uniquely named menu moved category, retain its ID and photo as well.
  UPDATE pg_temp.menu_import_stage_items s
  SET matched_item_id = (
    SELECT mi.id
    FROM public.menu_items mi
    WHERE mi.restaurant_id = p_store_id
      AND lower(btrim(mi.name)) = s.menu_key
      AND NOT EXISTS (
        SELECT 1
        FROM pg_temp.menu_import_stage_items used
        WHERE used.matched_item_id = mi.id
      )
    LIMIT 1
  )
  WHERE s.matched_item_id IS NULL
    AND (
      SELECT count(*)
      FROM pg_temp.menu_import_stage_items same_name
      WHERE same_name.menu_key = s.menu_key
        AND same_name.matched_item_id IS NULL
    ) = 1
    AND (
      SELECT count(*)
      FROM public.menu_items mi
      WHERE mi.restaurant_id = p_store_id
        AND lower(btrim(mi.name)) = s.menu_key
        AND NOT EXISTS (
          SELECT 1
          FROM pg_temp.menu_import_stage_items used
          WHERE used.matched_item_id = mi.id
        )
    ) = 1;

  SELECT count(*) INTO v_preserved_image_count
  FROM pg_temp.menu_import_stage_items s
  JOIN public.menu_items mi ON mi.id = s.matched_item_id
  WHERE mi.image_url IS NOT NULL
     OR mi.image_storage_path IS NOT NULL;

  UPDATE public.menu_items mi
  SET category_id = c.category_id,
      name = s.name,
      description = s.description,
      price = s.price,
      is_available = s.is_available,
      is_visible_public = s.is_visible_public,
      sort_order = s.sort_order,
      updated_at = now()
  FROM pg_temp.menu_import_stage_items s
  JOIN pg_temp.menu_import_stage_categories c
    ON c.category_key = s.category_key
  WHERE mi.id = s.matched_item_id;
  GET DIAGNOSTICS v_updated_item_count = ROW_COUNT;

  DELETE FROM public.menu_items mi
  WHERE mi.restaurant_id = p_store_id
    AND NOT EXISTS (
      SELECT 1
      FROM pg_temp.menu_import_stage_items s
      WHERE s.matched_item_id = mi.id
    );
  GET DIAGNOSTICS v_deleted_item_count = ROW_COUNT;

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
  )
  SELECT
    p_store_id,
    c.category_id,
    s.name,
    s.description,
    s.price,
    s.is_available,
    s.is_visible_public,
    s.sort_order,
    now(),
    now()
  FROM pg_temp.menu_import_stage_items s
  JOIN pg_temp.menu_import_stage_categories c
    ON c.category_key = s.category_key
  WHERE s.matched_item_id IS NULL;
  GET DIAGNOSTICS v_created_item_count = ROW_COUNT;

  DELETE FROM public.menu_categories c
  WHERE c.restaurant_id = p_store_id
    AND NOT EXISTS (
      SELECT 1
      FROM pg_temp.menu_import_stage_categories s
      WHERE s.category_id = c.id
    );
  GET DIAGNOSTICS v_deleted_category_count = ROW_COUNT;

  SELECT count(*) INTO v_category_count
  FROM pg_temp.menu_import_stage_categories;
  SELECT count(*) INTO v_item_count
  FROM pg_temp.menu_import_stage_items;

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  ) VALUES (
    auth.uid(),
    'admin_replace_menu_catalog',
    'restaurants',
    p_store_id,
    jsonb_build_object(
      'restaurant_id', p_store_id,
      'source', 'excel_import',
      'replaced_at_utc', now(),
      'old_category_count', v_old_category_count,
      'old_item_count', v_old_item_count,
      'category_count', v_category_count,
      'item_count', v_item_count,
      'created_category_count', v_created_category_count,
      'created_item_count', v_created_item_count,
      'updated_item_count', v_updated_item_count,
      'deleted_category_count', v_deleted_category_count,
      'deleted_item_count', v_deleted_item_count,
      'preserved_image_count', v_preserved_image_count
    )
  );

  RETURN jsonb_build_object(
    'created_category_count', v_created_category_count,
    'imported_item_count', v_item_count,
    'category_count', v_category_count,
    'item_count', v_item_count,
    'created_item_count', v_created_item_count,
    'updated_item_count', v_updated_item_count,
    'deleted_category_count', v_deleted_category_count,
    'deleted_item_count', v_deleted_item_count,
    'preserved_image_count', v_preserved_image_count
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth, pg_temp;

REVOKE ALL ON FUNCTION public.admin_import_menu_items(UUID, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_import_menu_items(UUID, JSONB) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_import_menu_items(UUID, JSONB) TO authenticated;
