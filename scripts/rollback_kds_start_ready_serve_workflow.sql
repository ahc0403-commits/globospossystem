BEGIN;

DO $guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.emergency_order_queue WHERE workflow_version = 2
  ) OR EXISTS (
    SELECT 1 FROM public.emergency_floor_ready_lots
  ) OR EXISTS (
    SELECT 1 FROM public.emergency_unserved_cancellations
  ) OR EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items
    WHERE kitchen_started_quantity <> kitchen_done_quantity
       OR excused_quantity > 0
  ) OR EXISTS (
    SELECT 1 FROM public.emergency_combo_component_items
    WHERE kitchen_started_quantity <> kitchen_done_quantity
       OR excused_quantity > 0
  ) THEN
    RAISE EXCEPTION 'KDS_START_READY_ROLLBACK_REQUIRES_DATA_MIGRATION';
  END IF;
END;
$guard$;

DROP FUNCTION IF EXISTS public.qr_get_active_order(text);
ALTER FUNCTION public.qr_get_active_order_pre_start_ready(text)
  RENAME TO qr_get_active_order;
GRANT EXECUTE ON FUNCTION public.qr_get_active_order(text)
  TO anon, authenticated, service_role;
DROP FUNCTION IF EXISTS public.emergency_enrich_qr_unserved_items(uuid,jsonb);

DROP FUNCTION IF EXISTS public.get_emergency_order_item_progress(uuid[]);
ALTER FUNCTION public.get_emergency_order_item_progress_pre_start_ready(uuid[])
  RENAME TO get_emergency_order_item_progress;
GRANT EXECUTE ON FUNCTION public.get_emergency_order_item_progress(uuid[])
  TO authenticated;
DROP FUNCTION IF EXISTS public.get_emergency_order_summaries(uuid[]);
ALTER FUNCTION public.get_emergency_order_summaries_pre_start_ready(uuid[])
  RENAME TO get_emergency_order_summaries;
GRANT EXECUTE ON FUNCTION public.get_emergency_order_summaries(uuid[])
  TO authenticated;

DROP FUNCTION IF EXISTS public.get_kds_ticket_v2(uuid);
ALTER FUNCTION public.get_kds_ticket_v2_pre_start_ready(uuid)
  RENAME TO get_kds_ticket_v2;
GRANT EXECUTE ON FUNCTION public.get_kds_ticket_v2(uuid) TO authenticated;
DROP FUNCTION IF EXISTS public.get_emergency_station_today_completed();
ALTER FUNCTION public.get_emergency_station_today_completed_pre_start_ready()
  RENAME TO get_emergency_station_today_completed;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_today_completed()
  TO authenticated;
DROP FUNCTION IF EXISTS public.get_emergency_station_snapshot();
ALTER FUNCTION public.get_emergency_station_snapshot_pre_start_ready()
  RENAME TO get_emergency_station_snapshot;
GRANT EXECUTE ON FUNCTION public.get_emergency_station_snapshot()
  TO authenticated;
DROP FUNCTION IF EXISTS public.emergency_enrich_start_ready_orders(jsonb);

DROP FUNCTION IF EXISTS public.cashier_cancel_unserved_v1(
  uuid,uuid,integer,text,uuid
);
DROP FUNCTION IF EXISTS public.cancel_order(uuid,uuid,boolean);
ALTER FUNCTION public.cancel_order_pre_start_ready(uuid,uuid,boolean)
  RENAME TO cancel_order;
GRANT EXECUTE ON FUNCTION public.cancel_order(uuid,uuid,boolean)
  TO authenticated, service_role;
DROP FUNCTION IF EXISTS public.cancel_order_item(uuid,uuid);
ALTER FUNCTION public.cancel_order_item_pre_start_ready(uuid,uuid)
  RENAME TO cancel_order_item;
GRANT EXECUTE ON FUNCTION public.cancel_order_item(uuid,uuid)
  TO authenticated, service_role;

DROP TRIGGER IF EXISTS zzz_kds_set_workflow_event_targets_trigger
  ON public.emergency_fulfillment_events;
DROP FUNCTION IF EXISTS public.kds_set_workflow_event_targets();
DROP FUNCTION IF EXISTS public.kds_serve_ready_order_v3(uuid,uuid);
DROP FUNCTION IF EXISTS public.kds_record_station_progress_v3(
  uuid,text,text,integer,uuid
);
DROP FUNCTION IF EXISTS public.emergency_void_latest_ready_lots(
  text,uuid,integer
);
DROP FUNCTION IF EXISTS public.emergency_next_floor_ready_sequence(uuid);
DROP TABLE IF EXISTS public.emergency_unserved_cancellations;
DROP TABLE IF EXISTS public.emergency_floor_ready_lots;
DROP TABLE IF EXISTS public.emergency_floor_ready_sequences;

DROP TRIGGER IF EXISTS emergency_combo_preserve_started_quantity_trigger
  ON public.emergency_combo_component_items;
DROP TRIGGER IF EXISTS emergency_preserve_started_quantity_trigger
  ON public.emergency_fulfillment_items;
DROP FUNCTION IF EXISTS public.emergency_preserve_started_quantity();
DROP TRIGGER IF EXISTS emergency_assign_queue_workflow_version_trigger
  ON public.emergency_order_queue;
DROP FUNCTION IF EXISTS public.emergency_assign_queue_workflow_version();

ALTER TABLE public.emergency_fulfillment_items
  DROP CONSTRAINT IF EXISTS emergency_fulfillment_quantity_chain;
ALTER TABLE public.emergency_fulfillment_items
  ADD CONSTRAINT emergency_fulfillment_quantity_chain CHECK (
    floor_served_quantity >= 0
    AND floor_served_quantity <= tray_dispatched_quantity
    AND tray_dispatched_quantity <= tray_received_quantity
    AND tray_received_quantity <= kitchen_done_quantity
    AND kitchen_done_quantity <= ordered_quantity
  );
ALTER TABLE public.emergency_combo_component_items
  DROP CONSTRAINT IF EXISTS emergency_combo_component_quantity_chain;
ALTER TABLE public.emergency_combo_component_items
  ADD CONSTRAINT emergency_combo_component_quantity_chain CHECK (
    floor_served_quantity >= 0
    AND floor_served_quantity <= tray_dispatched_quantity
    AND tray_dispatched_quantity <= tray_received_quantity
    AND tray_received_quantity <= kitchen_done_quantity
    AND kitchen_done_quantity <= ordered_quantity
  );
ALTER TABLE public.emergency_floor_direct_items
  DROP CONSTRAINT IF EXISTS emergency_floor_direct_quantity_check;
ALTER TABLE public.emergency_floor_direct_items
  ADD CONSTRAINT emergency_floor_direct_quantity_check CHECK (
    floor_served_quantity >= 0
    AND floor_served_quantity <= ordered_quantity
  );

ALTER TABLE public.emergency_fulfillment_events
  DROP CONSTRAINT IF EXISTS emergency_fulfillment_events_stage_check;
ALTER TABLE public.emergency_fulfillment_events
  ADD CONSTRAINT emergency_fulfillment_events_stage_check CHECK (stage IN (
    'order_received', 'kitchen_done', 'tray_received', 'tray_dispatched',
    'floor_served', 'floor_direct_ready', 'leftover_requested',
    'leftover_floor_to_tray', 'leftover_tray_to_kitchen',
    'leftover_kitchen_packaged', 'leftover_tray_to_floor',
    'leftover_floor_delivered'
  ));

ALTER TABLE public.emergency_fulfillment_items
  DROP COLUMN IF EXISTS kitchen_started_quantity,
  DROP COLUMN IF EXISTS excused_quantity;
ALTER TABLE public.emergency_combo_component_items
  DROP COLUMN IF EXISTS kitchen_started_quantity,
  DROP COLUMN IF EXISTS excused_quantity;
ALTER TABLE public.emergency_floor_direct_items
  DROP COLUMN IF EXISTS excused_quantity;
ALTER TABLE public.emergency_order_queue
  DROP COLUMN IF EXISTS workflow_version;

COMMIT;
