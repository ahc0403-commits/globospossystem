DO $$
DECLARE
  v_cutover_at timestamptz := coalesce(
    nullif(current_setting('app.photo_objet_single_slot_cutover_at', true), '')::timestamptz,
    (
      nullif(current_setting('app.photo_objet_single_slot_cutover_date', true), '')::date::timestamp
      AT TIME ZONE 'Asia/Ho_Chi_Minh'
    ),
    now()
  );
  v_bad integer;
BEGIN
  IF to_regclass('public.photo_objet_monitoring_policies') IS NULL
     OR to_regclass('public.photo_objet_expected_slots') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_2220_REQUIRED_LEDGER_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.photo_objet_monitoring_policies
    WHERE effective_to IS NULL
      AND schedule_version IN ('hcm-two-hour-2230-v2', 'hcm-eod-2220-v3')
  ) THEN
    RAISE EXCEPTION 'PHOTO_2220_OPEN_POLICY_MISSING';
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_objet_expected_slots slot
  JOIN public.photo_objet_monitoring_policies policy
    ON policy.id = slot.monitoring_policy_id
  WHERE policy.effective_to IS NULL
    AND policy.schedule_version = 'hcm-two-hour-2230-v2'
    AND slot.scheduled_at >= v_cutover_at
    AND (
      slot.status <> 'expected'
      OR slot.attempt_count <> 0
      OR slot.successful_run_id IS NOT NULL
      OR slot.last_failure_class IS NOT NULL
      OR slot.alerted_failure_class IS NOT NULL
      OR slot.alerted_at IS NOT NULL
    );
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2220_FUTURE_SLOT_ALREADY_USED: %', v_bad;
  END IF;
END $$;

SELECT 'PHOTO_2220_PREFLIGHT_OK' AS result;
