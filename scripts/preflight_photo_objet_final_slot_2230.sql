\set ON_ERROR_STOP on

DO $$
DECLARE
  v_cutover_date date := coalesce(
    nullif(current_setting('app.photo_objet_final_slot_cutover_date', true), '')::date,
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
  );
  v_bad integer;
BEGIN
  IF to_regclass('public.photo_objet_monitoring_policies') IS NULL
     OR to_regclass('public.photo_objet_expected_slots') IS NULL
     OR to_regclass('public.photo_objet_sales_raw') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_2230_PREFLIGHT_BASE_SCHEMA_MISSING';
  END IF;
  IF to_regprocedure('public.photo_objet_ensure_expected_slots(date,date)') IS NULL
     OR to_regprocedure(
       'public.photo_objet_expected_slot_health_at(timestamp with time zone,integer)'
     ) IS NULL THEN
    RAISE EXCEPTION 'PHOTO_2230_PREFLIGHT_FUNCTION_MISSING';
  END IF;
  IF NOT EXISTS (
    SELECT 1
    FROM public.photo_objet_monitoring_policies
    WHERE effective_to IS NULL
      AND schedule_version = 'hcm-two-hour-v1'
  ) THEN
    RAISE EXCEPTION 'PHOTO_2230_PREFLIGHT_OPEN_V1_POLICY_MISSING';
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_objet_monitoring_policies p
  JOIN public.restaurants r ON r.id = p.store_id
  WHERE p.effective_to IS NULL
    AND p.schedule_version = 'hcm-two-hour-v1'
    AND (
      p.effective_from > (
        v_cutover_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'
      )
      OR p.is_enabled IS DISTINCT FROM true
      OR r.is_active IS DISTINCT FROM true
      OR p.timezone <> 'Asia/Ho_Chi_Minh'
      OR p.grace_minutes <> 90
      OR p.final_slot_grace_minutes <> 90
    );
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2230_PREFLIGHT_POLICY_INVALID: %', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_objet_expected_slots slot
  JOIN public.photo_objet_monitoring_policies p
    ON p.id = slot.monitoring_policy_id
  WHERE p.effective_to IS NULL
    AND p.schedule_version = 'hcm-two-hour-v1'
    AND slot.slot_date_hcm >= v_cutover_date
    AND slot.slot_time_hcm = TIME '23:00'
    AND (
      slot.status <> 'expected'
      OR slot.attempt_count <> 0
      OR slot.successful_run_id IS NOT NULL
      OR slot.last_failure_class IS NOT NULL
      OR slot.alerted_failure_class IS NOT NULL
      OR slot.alerted_at IS NOT NULL
    );
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2230_PREFLIGHT_LEGACY_SLOT_ALREADY_USED: %', v_bad;
  END IF;
END $$;

SELECT 'PHOTO_OBJET_FINAL_SLOT_2230_PREFLIGHT_PASS' AS result;
