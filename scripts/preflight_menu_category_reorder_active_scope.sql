DO $menu_category_reorder_preflight$
BEGIN
  IF to_regclass('public.menu_categories') IS NULL
     OR to_regclass('public.audit_logs') IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_REORDER_PREFLIGHT_TABLES_MISSING';
  END IF;

  IF EXISTS (
    SELECT required.column_name
    FROM unnest(ARRAY[
      'id', 'restaurant_id', 'name', 'name_ko', 'sort_order',
      'is_active', 'created_at'
    ]) AS required(column_name)
    WHERE NOT EXISTS (
      SELECT 1
      FROM information_schema.columns present
      WHERE present.table_schema = 'public'
        AND present.table_name = 'menu_categories'
        AND present.column_name = required.column_name
    )
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_REORDER_PREFLIGHT_COLUMNS_MISSING';
  END IF;

  IF to_regprocedure(
    'public.admin_reorder_menu_categories(uuid,uuid[])'
  ) IS NULL OR to_regprocedure(
    'public.require_admin_actor_for_restaurant(uuid)'
  ) IS NULL THEN
    RAISE EXCEPTION 'MENU_CATEGORY_REORDER_PREFLIGHT_RPC_MISSING';
  END IF;
END;
$menu_category_reorder_preflight$;
