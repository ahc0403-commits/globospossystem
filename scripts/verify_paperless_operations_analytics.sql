DO $$
BEGIN
  IF to_regprocedure(
    'public.get_paperless_operations_report(uuid,timestamp with time zone,timestamp with time zone)'
  ) IS NULL OR position(
    'emergency_floor_direct_items' IN pg_get_functiondef(
      'public.get_paperless_operations_report(uuid,timestamp with time zone,timestamp with time zone)'::regprocedure
    )
  ) = 0 OR position(
    'bottleneck_station' IN pg_get_functiondef(
      'public.get_paperless_operations_report(uuid,timestamp with time zone,timestamp with time zone)'::regprocedure
    )
  ) = 0 THEN
    RAISE EXCEPTION 'PAPERLESS_OPERATIONS_ANALYTICS_MISSING';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.get_paperless_operations_report(uuid,timestamp with time zone,timestamp with time zone)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PAPERLESS_OPERATIONS_ANALYTICS_PRIVILEGE_MISSING';
  END IF;
END;
$$;
