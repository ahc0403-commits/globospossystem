DO $preflight$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
       'public.kds_complete_kitchen_batch_v1(uuid,jsonb)'
     ) IS NULL
     OR to_regprocedure(
       'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)'
     ) IS NULL
     OR to_regprocedure(
       'public.kds_complete_customer_delivery_batch_v1(uuid,jsonb)'
     ) IS NULL
     OR to_regprocedure(
       'public.kds_record_station_progress_v3(uuid,text,text,integer,uuid)'
     ) IS NULL
     OR to_regclass('public.emergency_tray_ready_lots') IS NULL
     OR to_regclass('public.emergency_floor_ready_lots') IS NULL
     OR to_regclass('public.emergency_fulfillment_events') IS NULL
     OR to_regclass('public.emergency_fulfillment_actions') IS NULL THEN
    RAISE EXCEPTION 'KDS_SUBSECOND_PREREQUISITES_MISSING';
  END IF;

  IF to_regprocedure(
       'public.kds_complete_kitchen_batch_loop_backup_v1(uuid,jsonb)'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.kds_dispatch_tray_floor_loop_backup_v1(uuid,text,jsonb)'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.kds_complete_customer_delivery_loop_backup_v1(uuid,jsonb)'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'KDS_SUBSECOND_UNEXPECTED_BASELINE';
  END IF;

  SELECT pg_get_functiondef(
    'public.kds_complete_kitchen_batch_v1(uuid,jsonb)'::regprocedure
  ) INTO v_definition;
  IF position('FOR v_allocation IN' IN v_definition) = 0
     OR position('kds_record_station_progress_v3(' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'KDS_SUBSECOND_KITCHEN_BASELINE_CHANGED';
  END IF;

  SELECT pg_get_functiondef(
    'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)'::regprocedure
  ) INTO v_definition;
  IF position('FOR v_allocation IN' IN v_definition) = 0
     OR position('kds_record_station_progress_v3(' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'KDS_SUBSECOND_TRAY_BASELINE_CHANGED';
  END IF;

  SELECT pg_get_functiondef(
    'public.kds_complete_customer_delivery_batch_v1(uuid,jsonb)'::regprocedure
  ) INTO v_definition;
  IF position('FOR v_allocation IN' IN v_definition) = 0
     OR position('kds_record_station_progress_v3(' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'KDS_SUBSECOND_FLOOR_BASELINE_CHANGED';
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
    SELECT 1 FROM public.emergency_combo_component_items component
    WHERE component.floor_served_quantity
            > component.tray_dispatched_quantity
       OR component.tray_dispatched_quantity
            > component.tray_received_quantity
       OR component.tray_received_quantity > component.kitchen_done_quantity
       OR component.kitchen_done_quantity
            > component.kitchen_started_quantity
       OR component.kitchen_started_quantity + component.excused_quantity
          > component.ordered_quantity
  ) THEN
    RAISE EXCEPTION 'KDS_SUBSECOND_EXISTING_QUANTITY_CHAIN_INVALID';
  END IF;
END;
$preflight$;
