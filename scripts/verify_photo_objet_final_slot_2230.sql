\set ON_ERROR_STOP on

DO $$
DECLARE
  v_cutover_date date;
  v_mapping_count integer;
  v_bad integer;
  v_raw_count bigint;
  v_raw_fingerprint text;
  v_policy_map_count bigint;
  v_policy_map_fingerprint text;
  v_expected_backup_count bigint;
  v_expected_backup_fingerprint text;
  v_actual_count bigint;
  v_actual_fingerprint text;
BEGIN
  IF to_regclass('public.photo_slot_20260714113000_state') IS NULL
     OR to_regclass('public.photo_slot_20260714113000_policy_map') IS NULL
     OR to_regclass('public.photo_slot_20260714113000_expected_backup') IS NULL
     OR to_regclass('public.photo_slot_20260714113000_raw_identity_backup') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_2230_VERIFY_BACKUP_MISSING';
  END IF;

  SELECT
    cutover_date, raw_row_count, raw_fingerprint,
    policy_map_row_count, policy_map_fingerprint,
    expected_backup_row_count, expected_backup_fingerprint
  INTO STRICT
    v_cutover_date, v_raw_count, v_raw_fingerprint,
    v_policy_map_count, v_policy_map_fingerprint,
    v_expected_backup_count, v_expected_backup_fingerprint
  FROM public.photo_slot_20260714113000_state
  WHERE migration_id = '20260714113000';

  IF v_policy_map_count IS NULL OR v_policy_map_fingerprint IS NULL
     OR v_expected_backup_count IS NULL
     OR v_expected_backup_fingerprint IS NULL THEN
    RAISE EXCEPTION 'PHOTO_2230_VERIFY_EVIDENCE_METADATA_INCOMPLETE';
  END IF;

  SELECT
    count(*)::bigint,
    md5(coalesce(string_agg(
      to_jsonb(mapping)::text,
      '|' ORDER BY mapping.old_policy_id
    ), ''))
  INTO v_actual_count, v_actual_fingerprint
  FROM public.photo_slot_20260714113000_policy_map mapping;
  IF v_actual_count <> v_policy_map_count
     OR v_actual_fingerprint IS DISTINCT FROM v_policy_map_fingerprint THEN
    RAISE EXCEPTION 'PHOTO_2230_VERIFY_POLICY_MAP_TAMPERED';
  END IF;

  SELECT
    count(*)::bigint,
    md5(coalesce(string_agg(
      to_jsonb(backup)::text,
      '|' ORDER BY backup.id
    ), ''))
  INTO v_actual_count, v_actual_fingerprint
  FROM public.photo_slot_20260714113000_expected_backup backup;
  IF v_actual_count <> v_expected_backup_count
     OR v_actual_fingerprint IS DISTINCT FROM v_expected_backup_fingerprint THEN
    RAISE EXCEPTION 'PHOTO_2230_VERIFY_EXPECTED_BACKUP_TAMPERED';
  END IF;

  SELECT count(*) INTO v_mapping_count
  FROM public.photo_slot_20260714113000_policy_map;
  IF v_mapping_count = 0 THEN
    RAISE EXCEPTION 'PHOTO_2230_VERIFY_POLICY_MAP_EMPTY';
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_slot_20260714113000_policy_map mapping
  LEFT JOIN public.photo_objet_monitoring_policies policy
    ON policy.id = mapping.new_policy_id
  WHERE policy.id IS NULL
    OR policy.effective_to IS NOT NULL
    OR policy.is_enabled IS DISTINCT FROM true
    OR policy.schedule_version <> 'hcm-two-hour-2230-v2'
    OR policy.timezone <> 'Asia/Ho_Chi_Minh'
    OR policy.grace_minutes <> 90
    OR policy.final_slot_grace_minutes <> 90;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2230_VERIFY_POLICY_FAILED: %', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_slot_20260714113000_policy_map mapping
  JOIN public.photo_objet_expected_slots slot
    ON slot.monitoring_policy_id = mapping.new_policy_id
  WHERE slot.slot_date_hcm >= v_cutover_date
    AND slot.slot_time_hcm = TIME '23:00';
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2230_VERIFY_LEGACY_SLOT_REMAINS: %', v_bad;
  END IF;

  WITH expected(slot_time) AS (
    VALUES
      (TIME '10:00'), (TIME '12:00'), (TIME '14:00'), (TIME '16:00'),
      (TIME '18:00'), (TIME '20:00'), (TIME '22:30')
  ), missing AS (
    SELECT mapping.new_policy_id, expected.slot_time
    FROM public.photo_slot_20260714113000_policy_map mapping
    CROSS JOIN expected
    LEFT JOIN public.photo_objet_expected_slots slot
      ON slot.monitoring_policy_id = mapping.new_policy_id
     AND slot.store_id = mapping.store_id
     AND slot.slot_date_hcm = v_cutover_date
     AND slot.slot_time_hcm = expected.slot_time
    WHERE slot.id IS NULL
  )
  SELECT count(*) INTO v_bad FROM missing;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2230_VERIFY_INITIAL_SLOT_MISSING: %', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_slot_20260714113000_policy_map mapping
  JOIN public.photo_objet_expected_slots slot
    ON slot.monitoring_policy_id = mapping.new_policy_id
   AND slot.store_id = mapping.store_id
   AND slot.slot_date_hcm = v_cutover_date
   AND slot.slot_time_hcm = TIME '22:30'
  JOIN public.photo_objet_monitoring_policies policy
    ON policy.id = mapping.new_policy_id
  WHERE slot.scheduled_at <> (
        (v_cutover_date + TIME '22:30') AT TIME ZONE 'Asia/Ho_Chi_Minh'
      )
     OR slot.due_at <> slot.scheduled_at
        + make_interval(mins => policy.final_slot_grace_minutes);
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2230_VERIFY_FINAL_DEADLINE_FAILED: %', v_bad;
  END IF;

  IF pg_get_functiondef(
    'public.photo_objet_ensure_expected_slots(date,date)'::regprocedure
  ) NOT LIKE '%hcm-two-hour-2230-v2%'
     OR pg_get_functiondef(
       'public.photo_objet_ensure_expected_slots(date,date)'::regprocedure
     ) NOT LIKE '%22:30%'
     OR pg_get_functiondef(
       'public.photo_objet_expected_slot_health_at(timestamp with time zone,integer)'::regprocedure
     ) NOT LIKE '%hcm-two-hour-2230-v2%' THEN
    RAISE EXCEPTION 'PHOTO_2230_VERIFY_FUNCTION_CONTRACT_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.photo_objet_monitoring_policies'::regclass
      AND conname = 'photo_objet_monitoring_policy_schedule_check'
      AND pg_get_constraintdef(oid, true) LIKE '%hcm-two-hour-2230-v2%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.photo_objet_expected_slots'::regclass
      AND conname = 'photo_objet_expected_slot_time_check'
      AND pg_get_constraintdef(oid, true) LIKE '%22:30%'
  ) THEN
    RAISE EXCEPTION 'PHOTO_2230_VERIFY_CONSTRAINT_FAILED';
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_slot_20260714113000_raw_identity_backup backup
  LEFT JOIN public.photo_objet_sales_raw raw
    ON raw.id = backup.id
   AND raw.store_id = backup.store_id
   AND raw.source_hash = backup.source_hash
  WHERE raw.id IS NULL;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2230_VERIFY_RAW_DATA_CHANGED';
  END IF;

  SELECT count(*)::bigint INTO v_actual_count
  FROM public.photo_slot_20260714113000_raw_identity_backup;
  IF v_actual_count <> v_raw_count OR (
    SELECT md5(coalesce(string_agg(
      backup.id::text || ':' || backup.store_id::text || ':' || backup.source_hash,
      '|' ORDER BY backup.id
    ), ''))
    FROM public.photo_slot_20260714113000_raw_identity_backup backup
  ) IS DISTINCT FROM v_raw_fingerprint THEN
    RAISE EXCEPTION 'PHOTO_2230_VERIFY_RAW_BACKUP_INVALID';
  END IF;
END $$;

SELECT 'PHOTO_OBJET_FINAL_SLOT_2230_VERIFY_PASS' AS result;
