DO $preflight$
BEGIN
  IF to_regclass('public.emergency_fulfillment_items') IS NULL
     OR to_regclass('public.emergency_combo_component_items') IS NULL
     OR to_regclass('public.emergency_tray_ready_sequences') IS NULL
     OR to_regclass('public.emergency_tray_ready_lots') IS NULL
     OR to_regclass('public.emergency_floor_ready_lots') IS NULL
     OR to_regprocedure(
       'public.kds_record_station_progress_v3(uuid,text,text,integer,uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_CUSTOMER_BATCH_PREREQUISITES_MISSING';
  END IF;

  IF to_regclass('public.emergency_tray_floor_batch_actions') IS NOT NULL
     OR to_regclass(
       'public.emergency_customer_delivery_batch_actions'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.kds_complete_customer_delivery_batch_v1(uuid,jsonb)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_CUSTOMER_BATCH_PARTIAL_INSTALL_DETECTED';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items item
    WHERE item.floor_served_quantity > item.tray_dispatched_quantity
       OR item.tray_dispatched_quantity > item.tray_received_quantity
       OR item.tray_received_quantity > item.kitchen_done_quantity
  ) OR EXISTS (
    SELECT 1 FROM public.emergency_combo_component_items item
    WHERE item.floor_served_quantity > item.tray_dispatched_quantity
       OR item.tray_dispatched_quantity > item.tray_received_quantity
       OR item.tray_received_quantity > item.kitchen_done_quantity
  ) THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_CUSTOMER_QUANTITY_CHAIN_INVALID';
  END IF;
END;
$preflight$;
