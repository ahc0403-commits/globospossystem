DO $menu_category_reorder_verify$
DECLARE
  v_function regprocedure := to_regprocedure(
    'public.admin_reorder_menu_categories(uuid,uuid[])'
  );
  v_definition text;
  v_config text[];
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_REORDER_VERIFY_RPC_MISSING';
  END IF;

  SELECT pg_get_functiondef(v_function), function.proconfig
  INTO v_definition, v_config
  FROM pg_proc function
  WHERE function.oid = v_function
    AND function.prosecdef;

  IF v_definition IS NULL
     OR NOT (
       COALESCE(v_config, ARRAY[]::text[])
         @> ARRAY['search_path=public, auth']
     )
     OR v_definition NOT LIKE '%AND is_active = true%'
     OR v_definition NOT LIKE '%AND category.is_active = true%'
     OR v_definition NOT LIKE '%MENU_CATEGORY_ORDER_SCOPE_MISMATCH%'
     OR has_function_privilege('anon', v_function, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_function, 'EXECUTE') THEN
    RAISE EXCEPTION 'MENU_CATEGORY_REORDER_VERIFY_RPC_SECURITY_OR_SCOPE_INVALID';
  END IF;

  IF EXISTS (
    WITH top7_stores AS (
      SELECT DISTINCT category.restaurant_id
      FROM public.menu_categories category
      WHERE category.is_active = true
        AND (
          lower(btrim(category.name)) = lower('메뉴 TOP7')
          OR lower(btrim(COALESCE(category.name_ko, ''))) = lower('메뉴 TOP7')
        )
    ),
    active_stats AS (
      SELECT
        category.restaurant_id,
        min(category.sort_order) AS minimum_sort_order,
        max(category.sort_order) AS maximum_sort_order,
        count(*) AS category_count,
        count(DISTINCT category.sort_order) AS distinct_sort_order_count,
        min(category.sort_order) FILTER (
          WHERE lower(btrim(category.name)) = lower('메뉴 TOP7')
             OR lower(btrim(COALESCE(category.name_ko, ''))) =
               lower('메뉴 TOP7')
        ) AS top7_sort_order
      FROM public.menu_categories category
      JOIN top7_stores store
        ON store.restaurant_id = category.restaurant_id
      WHERE category.is_active = true
      GROUP BY category.restaurant_id
    )
    SELECT 1
    FROM active_stats
    WHERE minimum_sort_order <> 0
       OR top7_sort_order <> 0
       OR maximum_sort_order <> category_count - 1
       OR distinct_sort_order_count <> category_count
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_REORDER_VERIFY_TOP7_ORDER_INVALID';
  END IF;
END;
$menu_category_reorder_verify$;
