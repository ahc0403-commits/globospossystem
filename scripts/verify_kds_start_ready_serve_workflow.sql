DO $verify$
DECLARE
  v_progress_definition text;
  v_cancel_definition text;
  v_void_definition text;
  v_queue_default text;
BEGIN
  IF to_regclass('public.emergency_floor_ready_sequences') IS NULL
     OR to_regclass('public.emergency_floor_ready_lots') IS NULL
     OR to_regclass('public.emergency_unserved_cancellations') IS NULL THEN
    RAISE EXCEPTION 'KDS_START_READY_TABLES_MISSING';
  END IF;

  IF to_regprocedure(
       'public.kds_record_station_progress_v3(uuid,text,text,integer,uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.kds_serve_ready_order_v3(uuid,uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.cashier_cancel_unserved_v1(uuid,uuid,integer,text,uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'KDS_START_READY_COMMANDS_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'emergency_order_queue'
      AND column_name = 'workflow_version' AND is_nullable = 'NO'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'emergency_fulfillment_items'
      AND column_name = 'kitchen_started_quantity'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'emergency_fulfillment_items'
      AND column_name = 'excused_quantity'
  ) THEN
    RAISE EXCEPTION 'KDS_START_READY_COLUMNS_MISSING';
  END IF;

  SELECT column_default INTO v_queue_default
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'emergency_order_queue'
    AND column_name = 'workflow_version';
  IF v_queue_default IS NULL OR position('2' IN v_queue_default) = 0 THEN
    RAISE EXCEPTION 'KDS_START_READY_NEW_QUEUE_DEFAULT_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items item
    WHERE item.floor_served_quantity > item.tray_dispatched_quantity
       OR item.tray_dispatched_quantity > item.tray_received_quantity
       OR item.tray_received_quantity > item.kitchen_done_quantity
       OR item.kitchen_done_quantity > item.kitchen_started_quantity
       OR item.kitchen_started_quantity + item.excused_quantity
          > item.ordered_quantity
  ) OR EXISTS (
    SELECT 1 FROM public.emergency_floor_direct_items item
    WHERE item.floor_served_quantity + item.excused_quantity
      > item.ordered_quantity
  ) THEN
    RAISE EXCEPTION 'KDS_START_READY_QUANTITY_CHAIN_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger
    WHERE tgrelid = 'public.emergency_fulfillment_events'::regclass
      AND tgname = 'zzz_kds_set_workflow_event_targets_trigger'
      AND NOT tgisinternal
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'emergency_floor_ready_lots'
      AND policyname = 'emergency_floor_ready_lots_store_read'
  ) THEN
    RAISE EXCEPTION 'KDS_START_READY_TRIGGER_OR_RLS_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.kds_record_station_progress_v3(uuid,text,text,integer,uuid)'
      ::regprocedure
  ) INTO v_progress_definition;
  SELECT pg_get_functiondef(
    'public.cashier_cancel_unserved_v1(uuid,uuid,integer,text,uuid)'
      ::regprocedure
  ) INTO v_cancel_definition;
  SELECT pg_get_functiondef(
    'public.emergency_void_latest_ready_lots(text,uuid,integer)'
      ::regprocedure
  ) INTO v_void_definition;
  IF position('v_ready > v_started' IN v_progress_definition) = 0
     OR position('ready_sequence DESC' IN v_void_definition) = 0
     OR position('floor_served_quantity' IN v_cancel_definition) = 0 THEN
    RAISE EXCEPTION 'KDS_START_READY_SERVER_GUARDS_MISSING';
  END IF;
END;
$verify$;
