BEGIN;

DO $guard$
BEGIN
  IF EXISTS (SELECT 1 FROM public.emergency_tray_floor_batch_actions)
     OR EXISTS (
       SELECT 1 FROM public.emergency_customer_delivery_batch_actions
     ) THEN
    RAISE EXCEPTION 'KDS_TRAY_FLOOR_CUSTOMER_BATCH_ROLLBACK_HAS_AUDIT_DATA';
  END IF;
END;
$guard$;

DROP FUNCTION IF EXISTS public.kds_complete_customer_delivery_batch_v1(
  uuid, jsonb
);
DROP FUNCTION IF EXISTS public.kds_dispatch_tray_floor_batch_v1(
  uuid, text, jsonb
);
DROP TABLE IF EXISTS public.emergency_customer_delivery_batch_actions;
DROP TABLE IF EXISTS public.emergency_tray_floor_batch_actions;

COMMIT;
