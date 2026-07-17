\set ON_ERROR_STOP on

DO $$
DECLARE
  v_cutover_date date;
  v_schedule_default text;
  v_schedule_constraint text;
  v_slot_constraint text;
  v_ensure_function text;
  v_health_function text;
  v_raw_count bigint;
  v_raw_fingerprint text;
  v_policy_map_count bigint;
  v_policy_map_fingerprint text;
  v_expected_backup_count bigint;
  v_expected_backup_fingerprint text;
  v_actual_count bigint;
  v_actual_fingerprint text;
  v_restore_to date;
  v_bad integer;
BEGIN
  IF to_regclass('public.photo_slot_20260714113000_state') IS NULL
     OR to_regclass('public.photo_slot_20260714113000_policy_map') IS NULL
     OR to_regclass('public.photo_slot_20260714113000_expected_backup') IS NULL
     OR to_regclass('public.photo_slot_20260714113000_raw_identity_backup') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_2230_ROLLBACK_STATE_MISSING';
  END IF;

  SELECT
    cutover_date, prior_schedule_default,
    prior_schedule_constraint_definition, prior_slot_constraint_definition,
    prior_ensure_function_definition, prior_health_function_definition,
    raw_row_count, raw_fingerprint,
    policy_map_row_count, policy_map_fingerprint,
    expected_backup_row_count, expected_backup_fingerprint
  INTO STRICT
    v_cutover_date, v_schedule_default,
    v_schedule_constraint, v_slot_constraint,
    v_ensure_function, v_health_function, v_raw_count, v_raw_fingerprint,
    v_policy_map_count, v_policy_map_fingerprint,
    v_expected_backup_count, v_expected_backup_fingerprint
  FROM public.photo_slot_20260714113000_state
  WHERE migration_id = '20260714113000';

  IF v_policy_map_count IS NULL OR v_policy_map_fingerprint IS NULL
     OR v_expected_backup_count IS NULL
     OR v_expected_backup_fingerprint IS NULL THEN
    RAISE EXCEPTION 'PHOTO_2230_ROLLBACK_EVIDENCE_METADATA_INCOMPLETE';
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
    RAISE EXCEPTION 'PHOTO_2230_ROLLBACK_POLICY_MAP_TAMPERED';
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
    RAISE EXCEPTION 'PHOTO_2230_ROLLBACK_EXPECTED_BACKUP_TAMPERED';
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_slot_20260714113000_policy_map mapping
  JOIN public.photo_objet_expected_slots slot
    ON slot.monitoring_policy_id = mapping.new_policy_id
  WHERE slot.slot_date_hcm >= v_cutover_date
    AND (
      (slot.slot_time_hcm = TIME '22:30' AND (
        slot.status <> 'expected'
        OR slot.attempt_count <> 0
        OR slot.successful_run_id IS NOT NULL
        OR slot.last_failure_class IS NOT NULL
        OR slot.alerted_failure_class IS NOT NULL
        OR slot.alerted_at IS NOT NULL
      ))
    );
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2230_ROLLBACK_LIVE_STATE_CHANGED: %', v_bad;
  END IF;

  SELECT count(*) INTO v_bad
  FROM public.photo_slot_20260714113000_raw_identity_backup backup
  LEFT JOIN public.photo_objet_sales_raw raw
    ON raw.id = backup.id
   AND raw.store_id = backup.store_id
   AND raw.source_hash = backup.source_hash
  WHERE raw.id IS NULL;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2230_ROLLBACK_RAW_DATA_DRIFT';
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
    RAISE EXCEPTION 'PHOTO_2230_ROLLBACK_RAW_BACKUP_INVALID';
  END IF;

  SELECT greatest(
    v_cutover_date,
    coalesce(max(slot.slot_date_hcm), v_cutover_date),
    coalesce((
      SELECT max(backup.slot_date_hcm)
      FROM public.photo_slot_20260714113000_expected_backup backup
    ), v_cutover_date)
  )
  INTO v_restore_to
  FROM public.photo_objet_expected_slots slot
  JOIN public.photo_slot_20260714113000_policy_map mapping
    ON mapping.new_policy_id = slot.monitoring_policy_id
  WHERE slot.slot_date_hcm >= v_cutover_date;

  DELETE FROM public.photo_objet_expected_slots slot
  USING public.photo_slot_20260714113000_policy_map mapping
  WHERE slot.monitoring_policy_id = mapping.new_policy_id
    AND slot.slot_date_hcm >= v_cutover_date
    AND slot.slot_time_hcm = TIME '22:30';

  UPDATE public.photo_objet_expected_slots slot
  SET monitoring_policy_id = mapping.old_policy_id
  FROM public.photo_slot_20260714113000_policy_map mapping
  WHERE mapping.reuse_policy = false
    AND slot.monitoring_policy_id = mapping.new_policy_id
    AND slot.slot_date_hcm >= v_cutover_date;

  INSERT INTO public.photo_objet_expected_slots (
    id, store_id, slot_date_hcm, slot_time_hcm, scheduled_at, due_at,
    monitoring_policy_id, status, successful_run_id, attempt_count,
    last_failure_class, alerted_failure_class, alerted_at, created_at, updated_at
  )
  SELECT
    id, store_id, slot_date_hcm, slot_time_hcm, scheduled_at, due_at,
    monitoring_policy_id, status, successful_run_id, attempt_count,
    last_failure_class, alerted_failure_class, alerted_at, created_at, updated_at
  FROM public.photo_slot_20260714113000_expected_backup
  WHERE slot_time_hcm = TIME '23:00'
  ON CONFLICT (id) DO NOTHING;

  DELETE FROM public.photo_objet_monitoring_policies policy
  USING public.photo_slot_20260714113000_policy_map mapping
  WHERE mapping.reuse_policy = false
    AND policy.id = mapping.new_policy_id;

  UPDATE public.photo_objet_monitoring_policies policy
  SET effective_to = mapping.old_effective_to,
      schedule_version = 'hcm-two-hour-v1'
  FROM public.photo_slot_20260714113000_policy_map mapping
  WHERE policy.id = mapping.old_policy_id;

  EXECUTE v_ensure_function;
  EXECUTE v_health_function;

  ALTER TABLE public.photo_objet_monitoring_policies
    DROP CONSTRAINT photo_objet_monitoring_policy_schedule_check;
  EXECUTE format(
    'ALTER TABLE public.photo_objet_monitoring_policies ADD CONSTRAINT %I %s',
    'photo_objet_monitoring_policy_schedule_check',
    v_schedule_constraint
  );
  IF v_schedule_default IS NULL THEN
    ALTER TABLE public.photo_objet_monitoring_policies
      ALTER COLUMN schedule_version DROP DEFAULT;
  ELSE
    EXECUTE 'ALTER TABLE public.photo_objet_monitoring_policies '
      || 'ALTER COLUMN schedule_version SET DEFAULT ' || v_schedule_default;
  END IF;

  ALTER TABLE public.photo_objet_expected_slots
    DROP CONSTRAINT photo_objet_expected_slot_time_check;
  EXECUTE format(
    'ALTER TABLE public.photo_objet_expected_slots ADD CONSTRAINT %I %s',
    'photo_objet_expected_slot_time_check',
    v_slot_constraint
  );

  PERFORM public.photo_objet_ensure_expected_slots(v_cutover_date, v_restore_to);
END $$;

DROP TABLE public.photo_slot_20260714113000_expected_backup;
DROP TABLE public.photo_slot_20260714113000_raw_identity_backup;
DROP TABLE public.photo_slot_20260714113000_policy_map;
DROP TABLE public.photo_slot_20260714113000_state;

SELECT 'PHOTO_OBJET_FINAL_SLOT_2230_ROLLBACK_PASS' AS result;
