\set ON_ERROR_STOP on

BEGIN;

DO $fixture$
DECLARE
  v_late_date date := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date - 1;
  v_late_at timestamptz := (v_late_date + TIME '22:00')
    AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_claimed boolean;
  v_status text;
  v_store_count integer;
  v_export_count integer;
BEGIN
  UPDATE public.photo_objet_monitoring_policies
  SET effective_to = v_late_at
  WHERE schedule_version = 'hcm-eod-2220-v3'
    AND effective_to IS NOT NULL;
  UPDATE public.photo_objet_monitoring_policies
  SET effective_from = v_late_at
  WHERE schedule_version = 'hcm-eod-2200-v4'
    AND effective_to IS NULL;

  DELETE FROM public.photo_objet_expected_slots
  WHERE slot_date_hcm = v_late_date;
  PERFORM public.photo_objet_ensure_expected_slots(v_late_date, v_late_date);

  WITH inserted AS (
    INSERT INTO public.photo_objet_sales_pull_runs (
      store_id, target_date, run_source, slot_id, slot_date_hcm,
      slot_time_hcm, interval_start_at, interval_end_at, interval_rows,
      status, finished_at
    )
    SELECT
      slot.store_id,
      v_late_date,
      'scheduled',
      'late-finalize-fixture:' || slot.store_id,
      v_late_date,
      TIME '22:00',
      v_late_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh',
      v_late_at,
      0,
      'success',
      now()
    FROM public.photo_objet_expected_slots slot
    JOIN public.photo_objet_monitoring_policies policy
      ON policy.id = slot.monitoring_policy_id
    WHERE slot.slot_date_hcm = v_late_date
      AND slot.slot_time_hcm = TIME '22:00'
      AND policy.schedule_version = 'hcm-eod-2200-v4'
    RETURNING id, store_id
  )
  UPDATE public.photo_objet_expected_slots slot
  SET status = 'recovered', successful_run_id = inserted.id
  FROM inserted
  WHERE slot.store_id = inserted.store_id
    AND slot.slot_date_hcm = v_late_date
    AND slot.slot_time_hcm = TIME '22:00';

  SELECT lease_acquired INTO v_claimed
  FROM public.photo_objet_claim_daily_execution(
    v_late_date, TIME '22:00', 'late-finalize-fixture', 'backup'
  );
  IF v_claimed IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'PHOTO_LATE_RECOVERY_FIXTURE_LEASE_NOT_ACQUIRED';
  END IF;

  SELECT report_status, store_count INTO v_status, v_store_count
  FROM public.photo_objet_finalize_daily_report(
    v_late_date, TIME '22:00', 'late-finalize-fixture'
  );
  IF v_status <> 'report_ready' OR v_store_count <> 6 THEN
    RAISE EXCEPTION 'PHOTO_LATE_RECOVERY_FIXTURE_REPORT_INVALID: %/%',
      v_status, v_store_count;
  END IF;
  IF NOT public.photo_objet_daily_report_is_ready(v_late_date) THEN
    RAISE EXCEPTION 'PHOTO_LATE_RECOVERY_FIXTURE_NOT_READY';
  END IF;

  SELECT count(*) INTO v_export_count
  FROM public.photo_objet_sales_export_runs(v_late_date);
  IF v_export_count <> 6 THEN
    RAISE EXCEPTION 'PHOTO_LATE_RECOVERY_FIXTURE_EXPORT_INVALID: %', v_export_count;
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.photo_objet_daily_executions execution
    WHERE execution.slot_date_hcm = v_late_date
      AND execution.report_ready_at > v_late_at + interval '25 minutes'
  ) THEN
    RAISE EXCEPTION 'PHOTO_LATE_RECOVERY_FIXTURE_WAS_NOT_LATE';
  END IF;
END
$fixture$;

ROLLBACK;

SELECT 'PHOTO_OBJET_LATE_SLOT_RECOVERY_ASSERTIONS_PASS' AS result;
