\set ON_ERROR_STOP on

DO $rollback$
DECLARE
  v_cutover_at timestamptz;
  v_restore_from date;
  v_has_running_execution boolean := false;
BEGIN
  IF to_regclass('public.photo_objet_daily_executions') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (
      SELECT 1 FROM public.photo_objet_daily_executions WHERE status = ''running''
    )'
    INTO v_has_running_execution;
  END IF;

  IF v_has_running_execution THEN
    RAISE EXCEPTION 'PHOTO_2200_ROLLBACK_ACTIVE_EXECUTION';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.photo_objet_expected_slots slot
    JOIN public.photo_objet_monitoring_policies policy
      ON policy.id = slot.monitoring_policy_id
    WHERE policy.schedule_version = 'hcm-eod-2200-v4'
      AND (
        slot.status <> 'expected'
        OR slot.attempt_count <> 0
        OR slot.successful_run_id IS NOT NULL
      )
  ) THEN
    RAISE EXCEPTION 'PHOTO_2200_ROLLBACK_ATTEMPTED_SLOT';
  END IF;

  SELECT min(effective_from), min((effective_from AT TIME ZONE 'Asia/Ho_Chi_Minh')::date)
  INTO v_cutover_at, v_restore_from
  FROM public.photo_objet_monitoring_policies
  WHERE effective_to IS NULL AND schedule_version = 'hcm-eod-2200-v4';
  IF v_cutover_at IS NULL THEN
    RAISE EXCEPTION 'PHOTO_2200_ROLLBACK_OPEN_V4_POLICY_MISSING';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.photo_objet_monitoring_policies
    WHERE effective_to IS NULL
      AND schedule_version = 'hcm-eod-2200-v4'
      AND effective_from <> v_cutover_at
  ) THEN
    RAISE EXCEPTION 'PHOTO_2200_ROLLBACK_CUTOVER_MISMATCH';
  END IF;

  DELETE FROM public.photo_objet_expected_slots slot
  USING public.photo_objet_monitoring_policies policy
  WHERE policy.id = slot.monitoring_policy_id
    AND policy.schedule_version = 'hcm-eod-2200-v4';
  DELETE FROM public.photo_objet_monitoring_policies
  WHERE schedule_version = 'hcm-eod-2200-v4' AND effective_to IS NULL;
  UPDATE public.photo_objet_monitoring_policies
  SET effective_to = NULL
  WHERE schedule_version = 'hcm-eod-2220-v3'
    AND effective_to = v_cutover_at;
  ALTER TABLE public.photo_objet_monitoring_policies
    ALTER COLUMN schedule_version SET DEFAULT 'hcm-eod-2220-v3';
  PERFORM public.photo_objet_ensure_expected_slots(v_restore_from, v_restore_from + 7);
END
$rollback$;

SELECT 'Photo Objet 22:00 collection rollback passed' AS result;
