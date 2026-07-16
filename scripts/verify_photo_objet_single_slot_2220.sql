DO $$
DECLARE
  v_cutover_date date;
  v_bad integer;
BEGIN
  SELECT cutover_date INTO STRICT v_cutover_date
  FROM public.photo_slot_20260716160000_state
  WHERE migration_id = '20260716160000';

  SELECT count(*) INTO v_bad
  FROM public.photo_slot_20260716160000_policy_map mapping
  LEFT JOIN public.photo_objet_monitoring_policies policy
    ON policy.id = mapping.new_policy_id
  WHERE policy.id IS NULL
     OR policy.effective_to IS NOT NULL
     OR policy.schedule_version <> 'hcm-eod-2220-v3'
     OR policy.store_id <> mapping.store_id
     OR policy.is_enabled IS DISTINCT FROM true;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2220_POLICY_VERIFY_FAILED: %', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_objet_monitoring_policies
  WHERE effective_to IS NULL
    AND schedule_version <> 'hcm-eod-2220-v3';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2220_LEGACY_OPEN_POLICY_REMAINS: %', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_slot_20260716160000_policy_map mapping
  LEFT JOIN public.photo_objet_expected_slots slot
    ON slot.monitoring_policy_id = mapping.new_policy_id
   AND slot.slot_date_hcm = v_cutover_date
   AND slot.slot_time_hcm = TIME '22:20'
  WHERE slot.id IS NULL
     OR slot.scheduled_at <> (
       (v_cutover_date + TIME '22:20') AT TIME ZONE 'Asia/Ho_Chi_Minh'
     )
     OR slot.due_at <> (
       (v_cutover_date + TIME '22:20') AT TIME ZONE 'Asia/Ho_Chi_Minh'
       + interval '90 minutes'
     );
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2220_EXPECTATION_VERIFY_FAILED: %', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_objet_expected_slots slot
  JOIN public.photo_slot_20260716160000_policy_map mapping
    ON mapping.new_policy_id = slot.monitoring_policy_id
  WHERE slot.slot_date_hcm >= v_cutover_date
    AND slot.slot_time_hcm <> TIME '22:20';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2220_EXTRA_V3_SLOTS: %', v_bad;
  END IF;

  IF pg_get_functiondef(
       'public.photo_objet_ensure_expected_slots(date,date)'::regprocedure
     ) NOT LIKE '%hcm-eod-2220-v3%'
     OR pg_get_functiondef(
       'public.photo_objet_ensure_expected_slots(date,date)'::regprocedure
     ) NOT LIKE '%22:20%' THEN
    RAISE EXCEPTION 'PHOTO_2220_FUNCTION_VERIFY_FAILED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM pg_trigger trigger
    WHERE trigger.tgrelid = 'public.photo_objet_sales_raw'::regclass
      AND trigger.tgname = 'trg_enqueue_photo_objet_meinvoice_job'
      AND NOT trigger.tgisinternal
  ) THEN
    RAISE EXCEPTION 'PHOTO_2220_MISA_ENQUEUE_TRIGGER_REMAINS';
  END IF;
END $$;

SELECT 'PHOTO_2220_VERIFY_OK' AS result;
