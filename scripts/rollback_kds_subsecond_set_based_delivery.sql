BEGIN;

-- Realtime publication membership is intentionally retained: it repairs the
-- legacy client's declared subscription contract and is independent of the
-- set-based mutation implementation.
DROP FUNCTION public.kds_complete_kitchen_batch_v1(uuid, jsonb);
DROP FUNCTION public.kds_dispatch_tray_floor_batch_v1(uuid, text, jsonb);
DROP FUNCTION public.kds_complete_customer_delivery_batch_v1(uuid, jsonb);

ALTER FUNCTION public.kds_complete_kitchen_batch_loop_backup_v1(uuid, jsonb)
  RENAME TO kds_complete_kitchen_batch_v1;
ALTER FUNCTION public.kds_dispatch_tray_floor_loop_backup_v1(
  uuid, text, jsonb
) RENAME TO kds_dispatch_tray_floor_batch_v1;
ALTER FUNCTION public.kds_complete_customer_delivery_loop_backup_v1(
  uuid, jsonb
) RENAME TO kds_complete_customer_delivery_batch_v1;

GRANT EXECUTE ON FUNCTION public.kds_complete_kitchen_batch_v1(uuid, jsonb)
  TO authenticated;
GRANT EXECUTE ON FUNCTION public.kds_dispatch_tray_floor_batch_v1(
  uuid, text, jsonb
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.kds_complete_customer_delivery_batch_v1(
  uuid, jsonb
) TO authenticated;

DROP FUNCTION public.kds_apply_station_progress_batch_v1(
  uuid, uuid, uuid, text, text, jsonb
);

DO $verify$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
       'public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb)'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.kds_complete_kitchen_batch_loop_backup_v1(uuid,jsonb)'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.kds_dispatch_tray_floor_loop_backup_v1(uuid,text,jsonb)'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.kds_complete_customer_delivery_loop_backup_v1(uuid,jsonb)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'KDS_SUBSECOND_ROLLBACK_NAMES_INVALID';
  END IF;

  SELECT pg_get_functiondef(
    'public.kds_complete_kitchen_batch_v1(uuid,jsonb)'::regprocedure
  ) INTO v_definition;
  IF position('FOR v_allocation IN' IN v_definition) = 0
     OR position('kds_record_station_progress_v3(' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'KDS_SUBSECOND_ROLLBACK_DEFINITION_INVALID';
  END IF;
END;
$verify$;

COMMIT;
