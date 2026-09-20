DO $verify$
DECLARE
  v_name text;
  v_definition text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
    'public.kds_complete_kitchen_batch_v1(uuid,jsonb)',
    'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)',
    'public.kds_complete_customer_delivery_batch_v1(uuid,jsonb)'
  ] LOOP
    SELECT pg_get_functiondef(v_name::regprocedure) INTO v_definition;
    IF v_definition ~* '\m(loop|foreach)\M'
       OR position('kds_record_station_progress_v3(' IN v_definition) > 0
       OR position('kds_record_progress_v2(' IN v_definition) > 0 THEN
      RAISE EXCEPTION 'KDS_SUBSECOND_N_PLUS_ONE_PRESENT: %', v_name;
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
      AND tablename = 'emergency_fulfillment_actions'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
      AND tablename = 'emergency_fulfillment_events'
  ) THEN
    RAISE EXCEPTION 'KDS_SUBSECOND_REALTIME_PUBLICATION_MISSING';
  END IF;

  IF has_function_privilege(
       'authenticated',
       'public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)',
       'EXECUTE'
     ) OR has_function_privilege(
       'authenticated',
       'public.kds_complete_kitchen_batch_loop_backup_v1(uuid,jsonb)',
       'EXECUTE'
     ) OR has_function_privilege(
       'authenticated',
       'public.kds_dispatch_tray_floor_loop_backup_v1(uuid,text,jsonb)',
       'EXECUTE'
     ) OR has_function_privilege(
       'authenticated',
       'public.kds_complete_customer_delivery_loop_backup_v1(uuid,jsonb)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'KDS_SUBSECOND_INTERNAL_FUNCTION_EXPOSED';
  END IF;

  IF NOT has_function_privilege(
       'authenticated',
       'public.kds_complete_kitchen_batch_v1(uuid,jsonb)', 'EXECUTE'
     ) OR NOT has_function_privilege(
       'authenticated',
       'public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)', 'EXECUTE'
     ) OR NOT has_function_privilege(
       'authenticated',
       'public.kds_complete_customer_delivery_batch_v1(uuid,jsonb)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'KDS_SUBSECOND_PUBLIC_FUNCTION_PRIVILEGES_INVALID';
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
    RAISE EXCEPTION 'KDS_SUBSECOND_QUANTITY_CHAIN_INVALID';
  END IF;
END;
$verify$;

SELECT jsonb_build_object(
  'kitchen_calls', COALESCE(sum(calls) FILTER (
    WHERE query LIKE '%kds_complete_kitchen_batch_v1%'
  ), 0),
  'kitchen_mean_ms', COALESCE(max(mean_exec_time) FILTER (
    WHERE query LIKE '%kds_complete_kitchen_batch_v1%'
  ), 0),
  'tray_mean_ms', COALESCE(max(mean_exec_time) FILTER (
    WHERE query LIKE '%kds_dispatch_tray_floor_batch_v1%'
  ), 0),
  'floor_mean_ms', COALESCE(max(mean_exec_time) FILTER (
    WHERE query LIKE '%kds_complete_customer_delivery_batch_v1%'
  ), 0)
) AS kds_batch_runtime_evidence
FROM pg_stat_statements;
