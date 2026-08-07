-- Move the authoritative Photo Objet collection from 22:20 to 22:00 HCM.
-- Historical policy/slot identities remain unchanged; only pristine future
-- expectations are transitioned to the v4 schedule.

ALTER TABLE public.photo_objet_monitoring_policies
  DROP CONSTRAINT IF EXISTS photo_objet_monitoring_policy_schedule_check;
ALTER TABLE public.photo_objet_monitoring_policies
  ADD CONSTRAINT photo_objet_monitoring_policy_schedule_check CHECK (
    schedule_version IN (
      'hcm-two-hour-v1',
      'hcm-two-hour-2230-v2',
      'hcm-eod-2220-v3',
      'hcm-eod-2200-v4'
    )
  );
ALTER TABLE public.photo_objet_monitoring_policies
  ALTER COLUMN schedule_version SET DEFAULT 'hcm-eod-2200-v4';

ALTER TABLE public.photo_objet_expected_slots
  DROP CONSTRAINT IF EXISTS photo_objet_expected_slot_time_check;
ALTER TABLE public.photo_objet_expected_slots
  ADD CONSTRAINT photo_objet_expected_slot_time_check CHECK (
    slot_time_hcm IN (
      TIME '10:00', TIME '12:00', TIME '14:00', TIME '16:00',
      TIME '18:00', TIME '20:00', TIME '22:00', TIME '22:20',
      TIME '22:30', TIME '23:00'
    )
  );

CREATE OR REPLACE FUNCTION public.photo_objet_policy_slot_times(
  p_schedule_version text
)
RETURNS time[]
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE p_schedule_version
    WHEN 'hcm-two-hour-v1' THEN ARRAY[
      TIME '10:00', TIME '12:00', TIME '14:00', TIME '16:00',
      TIME '18:00', TIME '20:00', TIME '23:00'
    ]
    WHEN 'hcm-two-hour-2230-v2' THEN ARRAY[
      TIME '10:00', TIME '12:00', TIME '14:00', TIME '16:00',
      TIME '18:00', TIME '20:00', TIME '22:30'
    ]
    WHEN 'hcm-eod-2220-v3' THEN ARRAY[TIME '22:20']
    WHEN 'hcm-eod-2200-v4' THEN ARRAY[TIME '22:00']
    ELSE ARRAY[]::time[]
  END
$$;

DO $transition$
DECLARE
  v_local_now timestamp := now() AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_cutover_date date;
  v_cutover_at timestamptz;
  v_unsafe_slots integer;
BEGIN
  v_cutover_date := v_local_now::date +
    CASE WHEN v_local_now::time < TIME '22:00' THEN 0 ELSE 1 END;
  v_cutover_at := (v_cutover_date + TIME '22:00')
    AT TIME ZONE 'Asia/Ho_Chi_Minh';

  SELECT count(*) INTO v_unsafe_slots
  FROM public.photo_objet_expected_slots slot
  JOIN public.photo_objet_monitoring_policies policy
    ON policy.id = slot.monitoring_policy_id
  WHERE policy.schedule_version = 'hcm-eod-2220-v3'
    AND slot.scheduled_at >= v_cutover_at
    AND (
      slot.status <> 'expected'
      OR slot.attempt_count <> 0
      OR slot.successful_run_id IS NOT NULL
    );
  IF v_unsafe_slots <> 0 THEN
    RAISE EXCEPTION 'PHOTO_2200_FUTURE_SLOT_ALREADY_ATTEMPTED: %', v_unsafe_slots;
  END IF;

  UPDATE public.photo_objet_monitoring_policies
  SET effective_to = v_cutover_at
  WHERE effective_to IS NULL
    AND schedule_version = 'hcm-eod-2220-v3';

  INSERT INTO public.photo_objet_monitoring_policies (
    store_id, effective_from, effective_to, timezone, schedule_version,
    grace_minutes, final_slot_grace_minutes, is_enabled
  )
  SELECT
    old.store_id, v_cutover_at, NULL, old.timezone, 'hcm-eod-2200-v4',
    old.grace_minutes, 25, old.is_enabled
  FROM public.photo_objet_monitoring_policies old
  WHERE old.schedule_version = 'hcm-eod-2220-v3'
    AND old.effective_to = v_cutover_at
  ON CONFLICT DO NOTHING;

  DELETE FROM public.photo_objet_expected_slots slot
  USING public.photo_objet_monitoring_policies policy
  WHERE policy.id = slot.monitoring_policy_id
    AND policy.schedule_version = 'hcm-eod-2220-v3'
    AND slot.scheduled_at >= v_cutover_at;
END
$transition$;

CREATE OR REPLACE FUNCTION public.photo_objet_ensure_expected_slots(
  p_from_date date,
  p_to_date date
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_inserted integer;
BEGIN
  IF p_from_date IS NULL OR p_to_date IS NULL OR p_to_date < p_from_date THEN
    RAISE EXCEPTION 'PHOTO_EXPECTED_SLOT_DATE_RANGE_INVALID';
  END IF;
  IF p_to_date - p_from_date > 92 THEN
    RAISE EXCEPTION 'PHOTO_EXPECTED_SLOT_DATE_RANGE_TOO_LARGE';
  END IF;

  WITH target_dates AS (
    SELECT generate_series(p_from_date, p_to_date, interval '1 day')::date AS slot_date
  ),
  candidates AS (
    SELECT
      policy.id AS policy_id,
      policy.store_id,
      target.slot_date,
      slots.slot_time,
      (target.slot_date + slots.slot_time) AT TIME ZONE policy.timezone AS scheduled_at,
      (target.slot_date + slots.slot_time) AT TIME ZONE policy.timezone
        + make_interval(mins => CASE
          WHEN slots.slot_time IN (
            TIME '22:00', TIME '22:20', TIME '22:30', TIME '23:00'
          ) THEN policy.final_slot_grace_minutes
          ELSE policy.grace_minutes
        END) AS due_at
    FROM public.photo_objet_monitoring_policies policy
    JOIN public.restaurants store
      ON store.id = policy.store_id AND store.is_active = true
    CROSS JOIN target_dates target
    CROSS JOIN LATERAL unnest(
      public.photo_objet_policy_slot_times(policy.schedule_version)
    ) slots(slot_time)
    WHERE policy.is_enabled = true
      AND (target.slot_date + slots.slot_time)
        AT TIME ZONE policy.timezone >= policy.effective_from
      AND (
        policy.effective_to IS NULL
        OR (target.slot_date + slots.slot_time)
          AT TIME ZONE policy.timezone < policy.effective_to
      )
  )
  INSERT INTO public.photo_objet_expected_slots (
    store_id, slot_date_hcm, slot_time_hcm, scheduled_at, due_at,
    monitoring_policy_id
  )
  SELECT store_id, slot_date, slot_time, scheduled_at, due_at, policy_id
  FROM candidates
  ON CONFLICT (store_id, slot_date_hcm, slot_time_hcm) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RETURN v_inserted;
END;
$$;

CREATE OR REPLACE FUNCTION public.photo_objet_expected_slot_health_at(
  p_observed_at timestamptz DEFAULT now(),
  p_lookback_days integer DEFAULT 2
)
RETURNS TABLE (
  store_id uuid, target_date date, policy_expected_slots integer,
  materialized_slots integer, coverage_missing_slots integer,
  policy_store_active boolean, due_slots integer, collected_slots integer,
  collected_zero_slots integer, recovered_slots integer, missing_slots integer,
  failed_slots integer, failure_classes text[], latest_due_slot timestamptz,
  status text, is_healthy boolean
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH target_dates AS (
    SELECT generate_series(
      (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date - (p_lookback_days - 1),
      (p_observed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
      interval '1 day'
    )::date AS target_date
    UNION
    SELECT DISTINCT slot.slot_date_hcm
    FROM public.photo_objet_expected_slots slot
    WHERE slot.status IN ('missing', 'failed')
  ),
  policy_candidates AS (
    SELECT
      policy.id AS policy_id,
      policy.store_id,
      target.target_date,
      slots.slot_time,
      store.is_active AS policy_store_active
    FROM public.photo_objet_monitoring_policies policy
    JOIN public.restaurants store ON store.id = policy.store_id
    CROSS JOIN target_dates target
    CROSS JOIN LATERAL unnest(
      public.photo_objet_policy_slot_times(policy.schedule_version)
    ) slots(slot_time)
    WHERE (
        policy.is_enabled = true
        OR EXISTS (
          SELECT 1 FROM public.photo_objet_expected_slots unresolved
          WHERE unresolved.monitoring_policy_id = policy.id
            AND unresolved.slot_date_hcm = target.target_date
            AND unresolved.status IN ('missing', 'failed')
        )
      )
      AND (target.target_date + slots.slot_time)
        AT TIME ZONE policy.timezone >= policy.effective_from
      AND (
        policy.effective_to IS NULL
        OR (target.target_date + slots.slot_time)
          AT TIME ZONE policy.timezone < policy.effective_to
      )
  )
  SELECT
    candidate.store_id,
    candidate.target_date,
    count(*)::integer,
    count(slot.id)::integer,
    (count(*) - count(slot.id))::integer,
    bool_and(candidate.policy_store_active),
    count(slot.id) FILTER (WHERE slot.due_at <= p_observed_at)::integer,
    count(slot.id) FILTER (
      WHERE slot.due_at <= p_observed_at AND slot.status = 'collected'
    )::integer,
    count(slot.id) FILTER (
      WHERE slot.due_at <= p_observed_at AND slot.status = 'collected_zero'
    )::integer,
    count(slot.id) FILTER (
      WHERE slot.due_at <= p_observed_at AND slot.status = 'recovered'
    )::integer,
    count(slot.id) FILTER (
      WHERE slot.due_at <= p_observed_at
        AND slot.status IN ('expected', 'running', 'missing')
    )::integer,
    count(slot.id) FILTER (
      WHERE slot.due_at <= p_observed_at AND slot.status = 'failed'
    )::integer,
    CASE
      WHEN count(slot.id) <> count(*)
        OR bool_and(candidate.policy_store_active) IS DISTINCT FROM true
      THEN array_prepend(
        'AUDIT_INFRA_FAILED'::text,
        coalesce(array_agg(DISTINCT slot.last_failure_class ORDER BY slot.last_failure_class)
          FILTER (WHERE slot.due_at <= p_observed_at
            AND slot.status IN ('missing', 'failed')
            AND slot.last_failure_class IS NOT NULL), ARRAY[]::text[])
      )
      ELSE coalesce(array_agg(DISTINCT slot.last_failure_class ORDER BY slot.last_failure_class)
        FILTER (WHERE slot.due_at <= p_observed_at
          AND slot.status IN ('missing', 'failed')
          AND slot.last_failure_class IS NOT NULL), ARRAY[]::text[])
    END,
    max(slot.scheduled_at) FILTER (WHERE slot.due_at <= p_observed_at),
    CASE
      WHEN bool_and(candidate.policy_store_active) IS DISTINCT FROM true
        THEN 'audit_infra_failed'
      WHEN count(slot.id) <> count(*) THEN 'audit_infra_failed'
      WHEN count(slot.id) FILTER (WHERE slot.due_at <= p_observed_at) = 0
        THEN 'not_due'
      WHEN count(slot.id) FILTER (
        WHERE slot.due_at <= p_observed_at AND slot.status = 'failed'
      ) > 0 THEN 'failed'
      WHEN count(slot.id) FILTER (
        WHERE slot.due_at <= p_observed_at
          AND slot.status IN ('expected', 'running', 'missing')
      ) > 0 THEN 'missing'
      ELSE 'healthy'
    END,
    bool_and(candidate.policy_store_active)
      AND count(slot.id) = count(*)
      AND count(slot.id) FILTER (WHERE slot.due_at <= p_observed_at) > 0
      AND count(slot.id) FILTER (
        WHERE slot.due_at <= p_observed_at
          AND slot.status IN ('expected', 'running', 'missing', 'failed')
      ) = 0
  FROM policy_candidates candidate
  LEFT JOIN public.photo_objet_expected_slots slot
    ON slot.monitoring_policy_id = candidate.policy_id
   AND slot.store_id = candidate.store_id
   AND slot.slot_date_hcm = candidate.target_date
   AND slot.slot_time_hcm = candidate.slot_time
  GROUP BY candidate.policy_id, candidate.store_id, candidate.target_date
$$;

DO $materialize$
DECLARE
  v_local_now timestamp := now() AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_from date;
BEGIN
  v_from := v_local_now::date +
    CASE WHEN v_local_now::time < TIME '22:00' THEN 0 ELSE 1 END;
  PERFORM public.photo_objet_ensure_expected_slots(v_from, v_from + 7);
END
$materialize$;

REVOKE ALL ON FUNCTION public.photo_objet_policy_slot_times(text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.photo_objet_policy_slot_times(text)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.photo_objet_policy_slot_times(text) IS
  'Authoritative effective-dated Photo Objet schedule mapping through v4 22:00 HCM.';
