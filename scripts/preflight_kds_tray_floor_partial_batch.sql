DO $preflight$
DECLARE
  v_definition text;
BEGIN
  IF to_regclass('public.emergency_tray_floor_batch_actions') IS NULL
     OR to_regclass('public.emergency_fulfillment_items') IS NULL
     OR to_regclass('public.emergency_combo_component_items') IS NULL
     OR to_regclass('public.emergency_tray_ready_sequences') IS NULL
     OR to_regprocedure(
       'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)'
     ) IS NULL
     OR to_regprocedure(
       'public.kds_record_station_progress_v3(uuid,text,text,integer,uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_PARTIAL_BATCH_PREREQUISITES_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)'::regprocedure
  ) INTO v_definition;
  IF position('v_server_snapshot <> v_client_snapshot' IN v_definition) = 0
     OR position(
       'current_line.quantity >= allocation.quantity' IN v_definition
     ) > 0 THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_PARTIAL_BATCH_UNEXPECTED_BASELINE';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items item
    WHERE item.tray_dispatched_quantity > item.tray_received_quantity
       OR item.tray_received_quantity > item.kitchen_done_quantity
  ) OR EXISTS (
    SELECT 1 FROM public.emergency_combo_component_items item
    WHERE item.tray_dispatched_quantity > item.tray_received_quantity
       OR item.tray_received_quantity > item.kitchen_done_quantity
  ) THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_PARTIAL_BATCH_QUANTITY_CHAIN_INVALID';
  END IF;
END;
$preflight$;
