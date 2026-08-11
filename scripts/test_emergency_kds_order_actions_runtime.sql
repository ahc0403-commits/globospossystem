SELECT public.emergency_complete_order_stage(
  '00000000-0000-0000-0000-000000000008',
  '00000000-0000-0000-0000-000000000010'
);

DO $kitchen_complete$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items
    WHERE id = '00000000-0000-0000-0000-000000000009'
      AND kitchen_done_quantity = 2
  ) THEN RAISE EXCEPTION 'KITCHEN_ORDER_COMPLETE_FAILED'; END IF;
END;
$kitchen_complete$;

SELECT public.emergency_complete_order_stage(
  '00000000-0000-0000-0000-000000000008',
  '00000000-0000-0000-0000-000000000010'
);

DO $deduplicated$
BEGIN
  IF (SELECT count(*) FROM public.emergency_fulfillment_actions
      WHERE action_id = '00000000-0000-0000-0000-000000000010') <> 1
     OR (SELECT count(*) FROM public.emergency_fulfillment_events
      WHERE action_id = '00000000-0000-0000-0000-000000000010') <> 1 THEN
    RAISE EXCEPTION 'ORDER_ACTION_DEDUPLICATION_FAILED';
  END IF;
END;
$deduplicated$;

SELECT public.emergency_revert_order_action(
  '00000000-0000-0000-0000-000000000008',
  '00000000-0000-0000-0000-000000000010',
  '00000000-0000-0000-0000-000000000011'
);

DO $kitchen_revert$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items
    WHERE id = '00000000-0000-0000-0000-000000000009'
      AND kitchen_done_quantity = 0
  ) THEN RAISE EXCEPTION 'KITCHEN_ORDER_REVERT_FAILED'; END IF;
END;
$kitchen_revert$;

UPDATE public.emergency_station_assignments
SET station_type = 'tray'
WHERE id = '00000000-0000-0000-0000-000000000007';
UPDATE public.emergency_fulfillment_items
SET kitchen_done_quantity = 2
WHERE id = '00000000-0000-0000-0000-000000000009';

SELECT public.emergency_complete_order_stage(
  '00000000-0000-0000-0000-000000000008',
  '00000000-0000-0000-0000-000000000012'
);

DO $tray_complete$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items
    WHERE id = '00000000-0000-0000-0000-000000000009'
      AND tray_received_quantity = 2
      AND tray_dispatched_quantity = 2
  ) THEN RAISE EXCEPTION 'TRAY_HANDOFF_COMPLETE_FAILED'; END IF;
END;
$tray_complete$;

UPDATE public.emergency_fulfillment_items
SET floor_served_quantity = 1
WHERE id = '00000000-0000-0000-0000-000000000009';

DO $downstream_guard$
BEGIN
  BEGIN
    PERFORM public.emergency_revert_order_action(
      '00000000-0000-0000-0000-000000000008',
      '00000000-0000-0000-0000-000000000012',
      '00000000-0000-0000-0000-000000000013'
    );
    RAISE EXCEPTION 'DOWNSTREAM_REVERT_WAS_NOT_BLOCKED';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%EMERGENCY_REVERT_DOWNSTREAM_PROGRESS%' THEN
        RAISE;
      END IF;
  END;
END;
$downstream_guard$;
