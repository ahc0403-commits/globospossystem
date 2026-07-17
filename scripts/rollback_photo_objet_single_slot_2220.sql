BEGIN;

DO $$
DECLARE
  v_state public.photo_slot_20260716160000_state%ROWTYPE;
  v_bad integer;
BEGIN
  SELECT * INTO STRICT v_state
  FROM public.photo_slot_20260716160000_state
  WHERE migration_id = '20260716160000';

  SELECT count(*) INTO v_bad
  FROM public.photo_objet_expected_slots slot
  JOIN public.photo_slot_20260716160000_policy_map mapping
    ON mapping.new_policy_id = slot.monitoring_policy_id
  WHERE slot.status <> 'expected'
     OR slot.attempt_count <> 0
     OR slot.successful_run_id IS NOT NULL
     OR slot.last_failure_class IS NOT NULL
     OR slot.alerted_failure_class IS NOT NULL
     OR slot.alerted_at IS NOT NULL;
  IF v_bad <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2220_ROLLBACK_ATTEMPTED_SLOTS: %', v_bad;
  END IF;

  DELETE FROM public.photo_objet_expected_slots slot
  USING public.photo_slot_20260716160000_policy_map mapping
  WHERE slot.monitoring_policy_id = mapping.new_policy_id;

  DELETE FROM public.photo_objet_monitoring_policies policy
  USING public.photo_slot_20260716160000_policy_map mapping
  WHERE policy.id = mapping.new_policy_id;

  UPDATE public.photo_objet_monitoring_policies policy
  SET effective_to = mapping.old_effective_to
  FROM public.photo_slot_20260716160000_policy_map mapping
  WHERE policy.id = mapping.old_policy_id;

  ALTER TABLE public.photo_objet_monitoring_policies
    DROP CONSTRAINT photo_objet_monitoring_policy_schedule_check;
  EXECUTE
    'ALTER TABLE public.photo_objet_monitoring_policies ADD CONSTRAINT '
    || 'photo_objet_monitoring_policy_schedule_check '
    || v_state.prior_schedule_constraint_definition;
  EXECUTE
    'ALTER TABLE public.photo_objet_monitoring_policies '
    || 'ALTER COLUMN schedule_version SET DEFAULT '
    || v_state.prior_schedule_default;

  ALTER TABLE public.photo_objet_expected_slots
    DROP CONSTRAINT photo_objet_expected_slot_time_check;
  EXECUTE
    'ALTER TABLE public.photo_objet_expected_slots ADD CONSTRAINT '
    || 'photo_objet_expected_slot_time_check '
    || v_state.prior_slot_constraint_definition;

  EXECUTE v_state.prior_ensure_function_definition;
  EXECUTE v_state.prior_health_function_definition;
  IF v_state.prior_enqueue_trigger_definition IS NOT NULL THEN
    EXECUTE v_state.prior_enqueue_trigger_definition;
  END IF;

  INSERT INTO public.photo_objet_expected_slots (
    id, store_id, slot_date_hcm, slot_time_hcm, scheduled_at, due_at,
    monitoring_policy_id, status, successful_run_id, attempt_count,
    last_failure_class, alerted_failure_class, alerted_at, created_at, updated_at
  )
  SELECT
    id, store_id, slot_date_hcm, slot_time_hcm, scheduled_at, due_at,
    monitoring_policy_id, status, successful_run_id, attempt_count,
    last_failure_class, alerted_failure_class, alerted_at, created_at, updated_at
  FROM public.photo_slot_20260716160000_expected_backup
  ON CONFLICT (id) DO NOTHING;
END $$;

DROP TABLE public.photo_slot_20260716160000_expected_backup;
DROP TABLE public.photo_slot_20260716160000_policy_map;
DROP TABLE public.photo_slot_20260716160000_state;

COMMIT;

SELECT 'PHOTO_2220_ROLLBACK_OK' AS result;
