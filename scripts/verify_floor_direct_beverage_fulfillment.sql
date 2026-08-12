DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'menu_items'
      AND column_name = 'fulfillment_route'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'order_items'
      AND column_name = 'fulfillment_route_snapshot'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurant_settings'
      AND column_name = 'floor_direct_beverages_enabled'
  ) THEN
    RAISE EXCEPTION 'FLOOR_DIRECT_FOUNDATION_COLUMNS_MISSING';
  END IF;

  IF to_regclass('public.emergency_floor_direct_items') IS NULL
     OR to_regprocedure(
       'public.admin_set_menu_fulfillment_route(uuid,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.super_admin_set_floor_direct_beverages(uuid,boolean,text,uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'FLOOR_DIRECT_FOUNDATION_OBJECTS_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'emergency_floor_direct_items'
      AND policyname = 'emergency_floor_direct_store_read'
  ) OR NOT has_function_privilege(
    'authenticated',
    'public.admin_set_menu_fulfillment_route(uuid,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FLOOR_DIRECT_FOUNDATION_SECURITY_MISSING';
  END IF;
END;
$$;
