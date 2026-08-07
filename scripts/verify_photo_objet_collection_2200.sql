\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_open_v4 integer;
  v_bad_v4 integer;
BEGIN
  SELECT count(*) INTO v_open_v4
  FROM public.photo_objet_monitoring_policies
  WHERE effective_to IS NULL
    AND schedule_version = 'hcm-eod-2200-v4'
    AND is_enabled = true;
  IF v_open_v4 <> 6 THEN
    RAISE EXCEPTION 'PHOTO_2200_REQUIRES_SIX_ACTIVE_V4_STORES: %', v_open_v4;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.photo_objet_monitoring_policies
    WHERE effective_to IS NULL AND schedule_version = 'hcm-eod-2220-v3'
  ) THEN
    RAISE EXCEPTION 'PHOTO_2200_OPEN_V3_POLICY_REMAINS';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.photo_objet_monitoring_policies
    WHERE effective_to IS NULL
      AND schedule_version = 'hcm-eod-2200-v4'
      AND final_slot_grace_minutes <> 25
  ) THEN
    RAISE EXCEPTION 'PHOTO_2200_REPORT_READY_GRACE_INVALID';
  END IF;

  SELECT count(*) INTO v_bad_v4
  FROM public.photo_objet_expected_slots slot
  JOIN public.photo_objet_monitoring_policies policy
    ON policy.id = slot.monitoring_policy_id
  WHERE policy.schedule_version = 'hcm-eod-2200-v4'
    AND slot.slot_time_hcm <> TIME '22:00';
  IF v_bad_v4 <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2200_V4_SLOT_TIME_INVALID: %', v_bad_v4;
  END IF;

  IF public.photo_objet_policy_slot_times('hcm-eod-2220-v3')
       <> ARRAY[TIME '22:20']
     OR public.photo_objet_policy_slot_times('hcm-eod-2200-v4')
       <> ARRAY[TIME '22:00'] THEN
    RAISE EXCEPTION 'PHOTO_2200_SCHEDULE_MAPPING_INVALID';
  END IF;
  IF NOT pg_get_functiondef(
       'public.photo_objet_expected_slot_health_at(timestamp with time zone,integer)'::regprocedure
     ) LIKE '%photo_objet_policy_slot_times%' THEN
    RAISE EXCEPTION 'PHOTO_2200_HEALTH_MAPPING_NOT_INSTALLED';
  END IF;
END
$verify$;

SELECT 'Photo Objet 22:00 collection verification passed' AS result;
