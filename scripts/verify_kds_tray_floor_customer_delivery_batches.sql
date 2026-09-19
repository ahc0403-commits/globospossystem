DO $verify$
DECLARE
  v_tray_definition text;
  v_customer_definition text;
BEGIN
  IF to_regclass('public.emergency_tray_floor_batch_actions') IS NULL
     OR to_regclass(
       'public.emergency_customer_delivery_batch_actions'
     ) IS NULL
     OR to_regclass(
       'public.emergency_tray_floor_batch_actions_restaurant_created_idx'
     ) IS NULL
     OR to_regclass(
       'public.emergency_tray_floor_batch_actions_created_by_idx'
     ) IS NULL
     OR to_regclass(
       'public.emergency_customer_delivery_batch_actions_restaurant_created_idx'
     ) IS NULL
     OR to_regclass(
       'public.emergency_customer_delivery_batch_actions_created_by_idx'
     ) IS NULL
     OR to_regprocedure(
       'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)'
     ) IS NULL
     OR to_regprocedure(
       'public.kds_complete_customer_delivery_batch_v1(uuid,jsonb)'
     ) IS NULL THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_CUSTOMER_BATCH_OBJECTS_MISSING';
  END IF;

  IF NOT has_function_privilege(
       'authenticated',
       'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.kds_complete_customer_delivery_batch_v1(uuid,jsonb)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.kds_complete_customer_delivery_batch_v1(uuid,jsonb)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_CUSTOMER_BATCH_PRIVILEGES_INVALID';
  END IF;

  SELECT pg_get_functiondef(
    'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)'::regprocedure
  ) INTO v_tray_definition;
  SELECT pg_get_functiondef(
    'public.kds_complete_customer_delivery_batch_v1(uuid,jsonb)'::regprocedure
  ) INTO v_customer_definition;
  IF position('KDS_TRAY_FLOOR_BATCH_STALE' IN v_tray_definition) = 0
     OR position('emergency_tray_ready_sequences' IN v_tray_definition) = 0
     OR position('FOR UPDATE OF component' IN v_tray_definition) = 0
     OR position('FOR UPDATE OF item' IN v_tray_definition) = 0
     OR position('KDS_CUSTOMER_DELIVERY_BATCH_STALE' IN v_customer_definition) = 0
     OR position('kds_record_station_progress_v3' IN v_customer_definition) = 0
     OR position('payments' IN lower(v_tray_definition)) > 0
     OR position('payments' IN lower(v_customer_definition)) > 0 THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_CUSTOMER_BATCH_GUARDS_MISSING';
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
$verify$;
