-- Allow the admin menu to reorder the active category list shown in the UI.
-- Inactive categories remain untouched and must not make the visible reorder fail.

WITH top7_stores AS (
  SELECT DISTINCT category.restaurant_id
  FROM public.menu_categories category
  WHERE category.is_active = true
    AND (
      lower(btrim(category.name)) = lower('메뉴 TOP7')
      OR lower(btrim(COALESCE(category.name_ko, ''))) = lower('메뉴 TOP7')
    )
),
ranked_categories AS (
  SELECT
    category.id,
    row_number() OVER (
      PARTITION BY category.restaurant_id
      ORDER BY
        CASE
          WHEN lower(btrim(category.name)) = lower('메뉴 TOP7')
            OR lower(btrim(COALESCE(category.name_ko, ''))) =
              lower('메뉴 TOP7') THEN 0
          ELSE 1
        END,
        category.sort_order,
        category.created_at,
        category.id
    ) - 1 AS normalized_sort_order
  FROM public.menu_categories category
  JOIN top7_stores store
    ON store.restaurant_id = category.restaurant_id
  WHERE category.is_active = true
)
UPDATE public.menu_categories category
SET sort_order = ranked.normalized_sort_order
FROM ranked_categories ranked
WHERE category.id = ranked.id
  AND category.sort_order IS DISTINCT FROM ranked.normalized_sort_order;

CREATE OR REPLACE FUNCTION public.admin_reorder_menu_categories(
  p_store_id uuid,
  p_category_ids uuid[]
) RETURNS SETOF public.menu_categories
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, auth
AS $$
DECLARE
  v_expected_count integer;
BEGIN
  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  IF p_category_ids IS NULL OR cardinality(p_category_ids) = 0 THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ORDER_REQUIRED';
  END IF;

  IF cardinality(p_category_ids) <> (
    SELECT count(DISTINCT input.category_id)
    FROM unnest(p_category_ids) AS input(category_id)
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ORDER_DUPLICATE';
  END IF;

  PERFORM 1
  FROM public.menu_categories
  WHERE restaurant_id = p_store_id
    AND is_active = true
  FOR UPDATE;

  SELECT count(*)
  INTO v_expected_count
  FROM public.menu_categories
  WHERE restaurant_id = p_store_id
    AND is_active = true;

  IF v_expected_count <> cardinality(p_category_ids)
     OR EXISTS (
       SELECT id
       FROM public.menu_categories
       WHERE restaurant_id = p_store_id
         AND is_active = true
       EXCEPT
       SELECT input.category_id
       FROM unnest(p_category_ids) AS input(category_id)
     )
     OR EXISTS (
       SELECT input.category_id
       FROM unnest(p_category_ids) AS input(category_id)
       EXCEPT
       SELECT id
       FROM public.menu_categories
       WHERE restaurant_id = p_store_id
         AND is_active = true
     ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_ORDER_SCOPE_MISMATCH';
  END IF;

  UPDATE public.menu_categories category
  SET sort_order = ordered.ordinality - 1
  FROM unnest(p_category_ids) WITH ORDINALITY ordered(category_id, ordinality)
  WHERE category.id = ordered.category_id
    AND category.restaurant_id = p_store_id
    AND category.is_active = true;

  INSERT INTO public.audit_logs(actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'admin_reorder_menu_categories',
    'restaurants',
    p_store_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'category_ids', to_jsonb(p_category_ids),
      'updated_at_utc', now()
    )
  );

  RETURN QUERY
  SELECT *
  FROM public.menu_categories
  WHERE restaurant_id = p_store_id
    AND is_active = true
  ORDER BY sort_order, created_at, id;
END;
$$;
