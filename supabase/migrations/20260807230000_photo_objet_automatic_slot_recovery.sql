-- Automatically recover unresolved Photo Objet end-of-day collection slots after
-- an external scheduler/runner outage. Recovery remains exact-slot typed and
-- cannot be satisfied by a manual or full-day backfill run.

CREATE OR REPLACE FUNCTION public.photo_objet_due_recovery_slots(
  p_observed_at timestamptz DEFAULT now(),
  p_slot_date_hcm date DEFAULT NULL,
  p_limit integer DEFAULT 6
)
RETURNS TABLE (
  store_id uuid,
  slot_date_hcm date,
  slot_time_hcm time,
  attempt_count integer,
  failure_class text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_observed_at IS NULL THEN
    RAISE EXCEPTION 'PHOTO_RECOVERY_OBSERVED_AT_REQUIRED';
  END IF;
  IF p_slot_date_hcm IS NULL THEN
    RAISE EXCEPTION 'PHOTO_RECOVERY_SLOT_DATE_REQUIRED';
  END IF;
  IF p_limit < 1 OR p_limit > 12 THEN
    RAISE EXCEPTION 'PHOTO_RECOVERY_LIMIT_INVALID';
  END IF;

  -- The prepared backup runner may take over one minute after 22:00. Only the
  -- requested current v4 business date is eligible; historical backlog must
  -- never consume the 22:00-22:25 reporting window.
  UPDATE public.photo_objet_expected_slots slot
  SET status = 'missing',
      last_failure_class = 'SLOT_MISSING',
      updated_at = now()
  FROM public.photo_objet_monitoring_policies policy,
       public.restaurants store
  WHERE policy.id = slot.monitoring_policy_id
    AND store.id = slot.store_id
    AND slot.scheduled_at + interval '1 minute' <= p_observed_at
    AND slot.slot_date_hcm = p_slot_date_hcm
    AND slot.status IN ('expected', 'running')
    AND slot.slot_time_hcm = TIME '22:00'
    AND policy.schedule_version = 'hcm-eod-2200-v4'
    AND policy.is_enabled = true
    AND store.is_active = true;

  RETURN QUERY
  SELECT
    slot.store_id,
    slot.slot_date_hcm,
    slot.slot_time_hcm,
    slot.attempt_count,
    slot.last_failure_class
  FROM public.photo_objet_expected_slots slot
  JOIN public.photo_objet_monitoring_policies policy
    ON policy.id = slot.monitoring_policy_id
  JOIN public.restaurants store
    ON store.id = slot.store_id
  WHERE slot.status IN ('missing', 'failed')
    AND policy.schedule_version = 'hcm-eod-2200-v4'
    AND slot.scheduled_at + interval '1 minute' <= p_observed_at
    AND slot.slot_date_hcm = p_slot_date_hcm
    AND slot.slot_time_hcm = TIME '22:00'
    AND policy.is_enabled = true
    AND store.is_active = true
  ORDER BY slot.store_id
  LIMIT p_limit;
END;
$$;

CREATE OR REPLACE FUNCTION public.photo_objet_complete_recovery_slot(
  p_store_id uuid,
  p_slot_date_hcm date,
  p_slot_time_hcm time,
  p_run_id uuid,
  p_zero_sales boolean
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_status text;
  v_interval_start timestamptz;
  v_interval_end timestamptz;
BEGIN
  IF p_slot_time_hcm <> TIME '22:00' THEN
    RAISE EXCEPTION 'PHOTO_RECOVERY_SLOT_UNSUPPORTED';
  END IF;

  v_interval_start := p_slot_date_hcm::timestamp
    AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_interval_end := (p_slot_date_hcm + p_slot_time_hcm)
    AT TIME ZONE 'Asia/Ho_Chi_Minh';

  IF NOT EXISTS (
    SELECT 1
    FROM public.photo_objet_sales_pull_runs run
    WHERE run.id = p_run_id
      AND run.store_id = p_store_id
      AND run.run_source = 'scheduled'
      AND run.status = 'success'
      AND run.slot_date_hcm = p_slot_date_hcm
      AND run.slot_time_hcm = p_slot_time_hcm
      AND run.interval_start_at = v_interval_start
      AND run.interval_end_at = v_interval_end
      AND run.interval_rows IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'PHOTO_RECOVERY_SUCCESS_RUN_MISMATCH';
  END IF;

  UPDATE public.photo_objet_expected_slots slot
  SET status = CASE
        WHEN slot.status IN ('collected', 'collected_zero', 'recovered')
          THEN slot.status
        ELSE 'recovered'
      END,
      successful_run_id = CASE
        WHEN slot.status IN ('collected', 'collected_zero', 'recovered')
          THEN slot.successful_run_id
        ELSE p_run_id
      END,
      updated_at = now()
  FROM public.photo_objet_monitoring_policies policy
  WHERE slot.store_id = p_store_id
    AND slot.slot_date_hcm = p_slot_date_hcm
    AND slot.slot_time_hcm = p_slot_time_hcm
    AND policy.id = slot.monitoring_policy_id
    AND policy.schedule_version = 'hcm-eod-2200-v4'
  RETURNING slot.status INTO v_status;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PHOTO_RECOVERY_EXPECTED_SLOT_NOT_FOUND';
  END IF;
  RETURN v_status;
END;
$$;

REVOKE ALL ON FUNCTION public.photo_objet_due_recovery_slots(timestamptz, date, integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.photo_objet_complete_recovery_slot(uuid, date, time, uuid, boolean)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.photo_objet_due_recovery_slots(timestamptz, date, integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.photo_objet_complete_recovery_slot(uuid, date, time, uuid, boolean)
  TO service_role;

COMMENT ON FUNCTION public.photo_objet_due_recovery_slots(timestamptz, date, integer) IS
  'Current-business-date v4 recovery queue; historical backlog is deliberately excluded from the reporting window.';
COMMENT ON FUNCTION public.photo_objet_complete_recovery_slot(uuid, date, time, uuid, boolean) IS
  'Marks an unresolved slot recovered only after an exact-interval scheduled recovery succeeds.';
