\set ON_ERROR_STOP on

DO $rollback$
DECLARE
  v_has_running_execution boolean := false;
BEGIN
  IF to_regclass('public.photo_objet_daily_executions') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (
      SELECT 1 FROM public.photo_objet_daily_executions WHERE status = ''running''
    )'
    INTO v_has_running_execution;
  END IF;

  IF v_has_running_execution THEN
    RAISE EXCEPTION 'PHOTO_RECOVERY_ROLLBACK_ACTIVE_EXECUTION';
  END IF;
END
$rollback$;

DROP FUNCTION IF EXISTS public.photo_objet_complete_recovery_slot(uuid, date, time, uuid, boolean);
DROP FUNCTION IF EXISTS public.photo_objet_due_recovery_slots(timestamptz, date, integer);

SELECT 'Photo Objet automatic slot recovery rollback passed' AS result;
