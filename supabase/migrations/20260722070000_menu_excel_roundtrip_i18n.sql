-- Atomic round-trip updates for exported menu/category workbooks.
-- Stable IDs preserve existing categories, menu items, and menu images.

CREATE OR REPLACE FUNCTION public.admin_update_menu_workbook_i18n(
  p_store_id uuid,
  p_categories jsonb,
  p_items jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth
AS $$
DECLARE
  v_entry record;
  v_row jsonb;
  v_source_row integer;
  v_store_id uuid;
  v_category_id uuid;
  v_item_id uuid;
  v_name_ko text;
  v_name_vi text;
  v_name_en text;
  v_description text;
  v_sort_order integer;
  v_price numeric(12, 2);
  v_is_available boolean;
  v_is_visible_public boolean;
  v_existing_category public.menu_categories%ROWTYPE;
  v_existing_item public.menu_items%ROWTYPE;
  v_updated_category_count integer := 0;
  v_updated_item_count integer := 0;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'MENU_WORKBOOK_STORE_REQUIRED';
  END IF;
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  IF p_categories IS NULL OR jsonb_typeof(p_categories) <> 'array'
     OR jsonb_array_length(p_categories) = 0
     OR jsonb_array_length(p_categories) > 500 THEN
    RAISE EXCEPTION 'MENU_WORKBOOK_CATEGORIES_INVALID';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array'
     OR jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'MENU_WORKBOOK_ITEMS_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_categories) entry
    GROUP BY entry ->> 'category_id'
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'MENU_WORKBOOK_CATEGORY_DUPLICATE';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) entry
    GROUP BY entry ->> 'item_id'
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'MENU_WORKBOOK_ITEM_DUPLICATE';
  END IF;

  FOR v_entry IN
    SELECT value, ordinality
    FROM jsonb_array_elements(p_categories) WITH ORDINALITY
  LOOP
    v_row := v_entry.value;
    v_source_row := COALESCE(
      CASE WHEN jsonb_typeof(v_row -> 'source_row') = 'number'
        THEN (v_row ->> 'source_row')::integer END,
      v_entry.ordinality::integer + 1
    );
    IF jsonb_typeof(v_row) <> 'object' THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_CATEGORY_ROW_INVALID:%', v_source_row;
    END IF;

    BEGIN
      v_store_id := (v_row ->> 'store_id')::uuid;
      v_category_id := (v_row ->> 'category_id')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_CATEGORY_ID_INVALID:%', v_source_row;
    END;
    IF v_store_id IS DISTINCT FROM p_store_id THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_STORE_MISMATCH:%', v_source_row;
    END IF;

    v_name_ko := NULLIF(btrim(COALESCE(v_row ->> 'name_ko', '')), '');
    v_name_vi := NULLIF(btrim(COALESCE(v_row ->> 'name_vi', '')), '');
    v_name_en := NULLIF(btrim(COALESCE(v_row ->> 'name_en', '')), '');
    IF v_name_ko IS NULL OR v_name_vi IS NULL OR v_name_en IS NULL
       OR char_length(v_name_ko) > 200
       OR char_length(v_name_vi) > 200
       OR char_length(v_name_en) > 200 THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_CATEGORY_NAME_INVALID:%', v_source_row;
    END IF;
    IF jsonb_typeof(v_row -> 'sort_order') <> 'number'
       OR (v_row ->> 'sort_order')::numeric < 0
       OR (v_row ->> 'sort_order')::numeric <> trunc((v_row ->> 'sort_order')::numeric) THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_CATEGORY_SORT_INVALID:%', v_source_row;
    END IF;
    v_sort_order := (v_row ->> 'sort_order')::integer;

    SELECT * INTO v_existing_category
    FROM public.menu_categories
    WHERE id = v_category_id AND restaurant_id = p_store_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_CATEGORY_NOT_FOUND:%', v_source_row;
    END IF;

    UPDATE public.menu_categories
    SET name = v_name_ko,
        name_ko = v_name_ko,
        name_vi = v_name_vi,
        name_en = v_name_en,
        sort_order = v_sort_order
    WHERE id = v_category_id;
    v_updated_category_count := v_updated_category_count + 1;

    IF v_existing_category.name_ko IS DISTINCT FROM v_name_ko
       OR v_existing_category.name_vi IS DISTINCT FROM v_name_vi
       OR v_existing_category.name_en IS DISTINCT FROM v_name_en
       OR v_existing_category.sort_order IS DISTINCT FROM v_sort_order THEN
      INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
      VALUES (
        auth.uid(), 'admin_update_menu_category', 'menu_categories', v_category_id,
        jsonb_build_object(
          'store_id', p_store_id,
          'source', 'excel_roundtrip',
          'source_row', v_source_row,
          'old_values', jsonb_build_object(
            'name_ko', v_existing_category.name_ko,
            'name_vi', v_existing_category.name_vi,
            'name_en', v_existing_category.name_en,
            'sort_order', v_existing_category.sort_order
          ),
          'new_values', jsonb_build_object(
            'name_ko', v_name_ko,
            'name_vi', v_name_vi,
            'name_en', v_name_en,
            'sort_order', v_sort_order
          )
        )
      );
    END IF;
  END LOOP;

  FOR v_entry IN
    SELECT value, ordinality
    FROM jsonb_array_elements(p_items) WITH ORDINALITY
  LOOP
    v_row := v_entry.value;
    v_source_row := COALESCE(
      CASE WHEN jsonb_typeof(v_row -> 'source_row') = 'number'
        THEN (v_row ->> 'source_row')::integer END,
      v_entry.ordinality::integer + 1
    );
    IF jsonb_typeof(v_row) <> 'object' THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_ITEM_ROW_INVALID:%', v_source_row;
    END IF;

    BEGIN
      v_store_id := (v_row ->> 'store_id')::uuid;
      v_category_id := (v_row ->> 'category_id')::uuid;
      v_item_id := (v_row ->> 'item_id')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_ITEM_ID_INVALID:%', v_source_row;
    END;
    IF v_store_id IS DISTINCT FROM p_store_id THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_STORE_MISMATCH:%', v_source_row;
    END IF;

    v_name_ko := NULLIF(btrim(COALESCE(v_row ->> 'name_ko', '')), '');
    v_name_vi := NULLIF(btrim(COALESCE(v_row ->> 'name_vi', '')), '');
    v_name_en := NULLIF(btrim(COALESCE(v_row ->> 'name_en', '')), '');
    v_description := NULLIF(btrim(COALESCE(v_row ->> 'description', '')), '');
    IF v_name_ko IS NULL OR v_name_vi IS NULL OR v_name_en IS NULL
       OR char_length(v_name_ko) > 200
       OR char_length(v_name_vi) > 200
       OR char_length(v_name_en) > 200
       OR char_length(COALESCE(v_description, '')) > 1000 THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_ITEM_TEXT_INVALID:%', v_source_row;
    END IF;
    IF jsonb_typeof(v_row -> 'price') <> 'number'
       OR (v_row ->> 'price')::numeric <= 0 THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_ITEM_PRICE_INVALID:%', v_source_row;
    END IF;
    v_price := (v_row ->> 'price')::numeric(12, 2);
    IF jsonb_typeof(v_row -> 'sort_order') <> 'number'
       OR (v_row ->> 'sort_order')::numeric < 0
       OR (v_row ->> 'sort_order')::numeric <> trunc((v_row ->> 'sort_order')::numeric) THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_ITEM_SORT_INVALID:%', v_source_row;
    END IF;
    v_sort_order := (v_row ->> 'sort_order')::integer;
    IF jsonb_typeof(v_row -> 'is_available') <> 'boolean'
       OR jsonb_typeof(v_row -> 'is_visible_public') <> 'boolean' THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_ITEM_BOOLEAN_INVALID:%', v_source_row;
    END IF;
    v_is_available := (v_row ->> 'is_available')::boolean;
    v_is_visible_public := (v_row ->> 'is_visible_public')::boolean;

    SELECT * INTO v_existing_item
    FROM public.menu_items
    WHERE id = v_item_id AND restaurant_id = p_store_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_ITEM_NOT_FOUND:%', v_source_row;
    END IF;
    IF v_existing_item.category_id IS DISTINCT FROM v_category_id THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_ITEM_CATEGORY_MISMATCH:%', v_source_row;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.menu_categories
      WHERE id = v_category_id AND restaurant_id = p_store_id
    ) THEN
      RAISE EXCEPTION 'MENU_WORKBOOK_CATEGORY_NOT_FOUND:%', v_source_row;
    END IF;

    UPDATE public.menu_items
    SET name = v_name_ko,
        name_ko = v_name_ko,
        name_vi = v_name_vi,
        name_en = v_name_en,
        description = v_description,
        price = v_price,
        is_available = v_is_available,
        is_visible_public = v_is_visible_public,
        sort_order = v_sort_order,
        updated_at = now()
    WHERE id = v_item_id;
    v_updated_item_count := v_updated_item_count + 1;

    IF v_existing_item.name_ko IS DISTINCT FROM v_name_ko
       OR v_existing_item.name_vi IS DISTINCT FROM v_name_vi
       OR v_existing_item.name_en IS DISTINCT FROM v_name_en
       OR v_existing_item.description IS DISTINCT FROM v_description
       OR v_existing_item.price IS DISTINCT FROM v_price
       OR v_existing_item.is_available IS DISTINCT FROM v_is_available
       OR v_existing_item.is_visible_public IS DISTINCT FROM v_is_visible_public
       OR v_existing_item.sort_order IS DISTINCT FROM v_sort_order THEN
      INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
      VALUES (
        auth.uid(), 'admin_update_menu_item', 'menu_items', v_item_id,
        jsonb_build_object(
          'store_id', p_store_id,
          'source', 'excel_roundtrip',
          'source_row', v_source_row,
          'old_values', jsonb_build_object(
            'name_ko', v_existing_item.name_ko,
            'name_vi', v_existing_item.name_vi,
            'name_en', v_existing_item.name_en,
            'description', v_existing_item.description,
            'price', v_existing_item.price,
            'is_available', v_existing_item.is_available,
            'is_visible_public', v_existing_item.is_visible_public,
            'sort_order', v_existing_item.sort_order
          ),
          'new_values', jsonb_build_object(
            'name_ko', v_name_ko,
            'name_vi', v_name_vi,
            'name_en', v_name_en,
            'description', v_description,
            'price', v_price,
            'is_available', v_is_available,
            'is_visible_public', v_is_visible_public,
            'sort_order', v_sort_order
          )
        )
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'updated_category_count', v_updated_category_count,
    'updated_item_count', v_updated_item_count
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_update_menu_workbook_i18n(uuid, jsonb, jsonb)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_update_menu_workbook_i18n(uuid, jsonb, jsonb)
  TO authenticated;
