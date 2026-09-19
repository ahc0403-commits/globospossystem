DO $verify$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
       'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)'
     ) IS NULL THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_PARTIAL_BATCH_FUNCTION_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)'::regprocedure
  ) INTO v_definition;
  IF position(
       'current_line.quantity >= allocation.quantity' IN v_definition
     ) = 0
     OR position('v_server_snapshot <> v_client_snapshot' IN v_definition) > 0
     OR position('KDS_TRAY_FLOOR_BATCH_STALE' IN v_definition) = 0
     OR position('FOR UPDATE OF component, queue NOWAIT' IN v_definition) = 0
     OR position('FOR UPDATE OF item, queue NOWAIT' IN v_definition) = 0
     OR position('kds_record_station_progress_v3' IN v_definition) = 0
     OR position('payments' IN lower(v_definition)) > 0 THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_PARTIAL_BATCH_GUARDS_MISSING';
  END IF;

  IF NOT has_function_privilege(
       'authenticated',
       'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_PARTIAL_BATCH_PRIVILEGES_INVALID';
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
$verify$;
