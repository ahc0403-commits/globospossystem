DO $$
BEGIN
  IF position(
    'emergency_floor_direct_items' IN pg_get_functiondef(
      'public.get_emergency_station_snapshot()'::regprocedure
    )
  ) = 0 OR position(
    'emergency_floor_direct_items' IN pg_get_functiondef(
      'public.get_emergency_order_summaries(uuid[])'::regprocedure
    )
  ) = 0 OR to_regprocedure(
    'public.get_emergency_order_item_progress(uuid[])'
  ) IS NULL THEN
    RAISE EXCEPTION 'FLOOR_DIRECT_READ_CONTRACT_MISSING';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.get_emergency_order_item_progress(uuid[])',
    'EXECUTE'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.emergency_floor_direct_items'::regclass
      AND tgname = 'close_drained_floor_direct_session_trigger'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'FLOOR_DIRECT_READ_SECURITY_OR_DRAIN_MISSING';
  END IF;
END;
$$;
