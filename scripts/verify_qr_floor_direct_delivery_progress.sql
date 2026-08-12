DO $$
BEGIN
  IF position(
    'fulfillment_parts' IN pg_get_functiondef(
      'public.qr_get_active_order(text)'::regprocedure
    )
  ) = 0 OR position(
    'emergency_floor_direct_items' IN pg_get_functiondef(
      'public.qr_get_active_order(text)'::regprocedure
    )
  ) = 0 THEN
    RAISE EXCEPTION 'QR_FLOOR_DIRECT_PROGRESS_MISSING';
  END IF;

  IF NOT has_function_privilege(
    'anon', 'public.qr_get_active_order(text)', 'EXECUTE'
  ) OR NOT has_function_privilege(
    'authenticated', 'public.qr_get_active_order(text)', 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'QR_FLOOR_DIRECT_PROGRESS_PRIVILEGES_MISSING';
  END IF;
END;
$$;
