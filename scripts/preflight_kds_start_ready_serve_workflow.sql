DO $preflight$
DECLARE
  v_cancel_order regprocedure;
BEGIN
  IF to_regclass('public.emergency_order_queue') IS NULL
     OR to_regclass('public.emergency_fulfillment_items') IS NULL
     OR to_regclass('public.emergency_combo_component_items') IS NULL
     OR to_regclass('public.emergency_floor_direct_items') IS NULL
     OR to_regclass('public.emergency_fulfillment_events') IS NULL
     OR to_regclass('public.kds_change_log') IS NULL THEN
    RAISE EXCEPTION 'KDS_START_READY_BASE_TABLES_MISSING';
  END IF;

  IF to_regprocedure('public.get_emergency_station_snapshot()') IS NULL
     OR to_regprocedure('public.get_emergency_station_today_completed()') IS NULL
     OR to_regprocedure('public.get_kds_ticket_v2(uuid)') IS NULL
     OR to_regprocedure(
       'public.get_emergency_order_summaries(uuid[])'
     ) IS NULL
     OR to_regprocedure(
       'public.get_emergency_order_item_progress(uuid[])'
     ) IS NULL
     OR to_regprocedure('public.qr_get_active_order(text)') IS NULL
     OR to_regprocedure('public.cancel_order_item(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'KDS_START_READY_BASE_FUNCTIONS_MISSING';
  END IF;
  v_cancel_order := to_regprocedure(
    'public.cancel_order(uuid,uuid,boolean)'
  );
  IF v_cancel_order IS NULL THEN
    RAISE EXCEPTION 'KDS_START_READY_CANCEL_ORDER_SIGNATURE_MISSING';
  END IF;

  IF to_regclass('public.emergency_floor_ready_lots') IS NOT NULL
     OR to_regclass('public.emergency_unserved_cancellations') IS NOT NULL
     OR to_regprocedure(
       'public.kds_record_station_progress_v3(uuid,text,text,integer,uuid)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'KDS_START_READY_PARTIAL_INSTALL_DETECTED';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items item
    WHERE item.floor_served_quantity > item.tray_dispatched_quantity
       OR item.tray_dispatched_quantity > item.tray_received_quantity
       OR item.tray_received_quantity > item.kitchen_done_quantity
       OR item.kitchen_done_quantity > item.ordered_quantity
  ) OR EXISTS (
    SELECT 1 FROM public.emergency_combo_component_items item
    WHERE item.floor_served_quantity > item.tray_dispatched_quantity
       OR item.tray_dispatched_quantity > item.tray_received_quantity
       OR item.tray_received_quantity > item.kitchen_done_quantity
       OR item.kitchen_done_quantity > item.ordered_quantity
  ) THEN
    RAISE EXCEPTION 'KDS_START_READY_EXISTING_QUANTITY_CHAIN_INVALID';
  END IF;
END;
$preflight$;
