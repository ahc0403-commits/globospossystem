DO $$
BEGIN
  IF position(
    'emergency_floor_direct_items' IN pg_get_functiondef(
      'public.super_admin_set_fulfillment_mode(uuid,text,text,uuid)'::regprocedure
    )
  ) = 0 OR position(
    'floor_direct_beverages_enabled' IN pg_get_functiondef(
      'public.super_admin_get_fulfillment_store_statuses()'::regprocedure
    )
  ) = 0 THEN
    RAISE EXCEPTION 'FLOOR_DIRECT_SETTINGS_CONTRACT_MISSING';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.super_admin_set_fulfillment_mode(uuid,text,text,uuid)',
    'EXECUTE'
  ) OR NOT has_function_privilege(
    'authenticated',
    'public.super_admin_get_fulfillment_store_statuses()',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'FLOOR_DIRECT_SETTINGS_PRIVILEGES_MISSING';
  END IF;
END;
$$;
