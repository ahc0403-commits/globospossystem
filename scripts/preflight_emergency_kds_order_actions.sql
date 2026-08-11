DO $preflight$
BEGIN
  IF to_regclass('public.emergency_fulfillment_sessions') IS NULL
     OR to_regclass('public.emergency_station_assignments') IS NULL
     OR to_regclass('public.emergency_order_queue') IS NULL
     OR to_regclass('public.emergency_fulfillment_items') IS NULL
     OR to_regclass('public.emergency_fulfillment_events') IS NULL THEN
    RAISE EXCEPTION 'EMERGENCY_KDS_BASE_TABLES_MISSING';
  END IF;

  IF to_regprocedure('public.get_emergency_station_snapshot()') IS NULL
     OR to_regprocedure(
       'public.emergency_record_progress(uuid,text,integer,uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.emergency_enqueue_push(uuid,uuid,uuid,text,text,text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'EMERGENCY_KDS_BASE_FUNCTIONS_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'emergency_fulfillment_items'
      AND column_name = 'tray_dispatched_quantity'
  ) THEN
    RAISE EXCEPTION 'EMERGENCY_KDS_QUANTITY_CHAIN_MISSING';
  END IF;
END;
$preflight$;
